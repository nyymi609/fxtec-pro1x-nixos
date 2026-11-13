// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * pro1x-fpd: the Pro1X fingerprint daemon, and its client.
 *
 *   pro1x-fpd --daemon          as root: hold the sensor, serve the socket
 *   pro1x-fpd status|list|identify|enroll NAME|remove ID|rename ID NAME
 *
 * The sensor sits on an SPI bus that TrustZone owns; only the stock trusted
 * app, mafp, can read it (../README.md).  The daemon opens one session to it
 * through the QSEECOM TEE driver, brings it up the way Android's library
 * does, and serves one client at a time on SOCKET with a line protocol:
 *
 *   status          -> "ready chip 0x24 fingers N"
 *   list            -> "finger ID NAME"..., then "ok"
 *   identify        -> "nomatch"... until "match ID NAME"
 *   enroll NAME     -> "touch", "sample N/14" or "retry REASON", ... "enrolled ID"
 *   remove ID       -> "ok"
 *   rename ID NAME  -> "ok"
 *
 * and "error TEXT" for a failure.  A client ends an operation by closing the
 * connection: the lock screen's module does when it goes away.
 *
 * The sensor is only read during identify and enroll, and identify pauses
 * while the panel is off (DPMS), so the phone is not kept busy: nothing
 * polls it otherwise.  While it pauses, the sensor's interrupt is armed
 * instead (arm_interrupt): a touch wakes the phone and is read with the
 * panel still off, and only a match turns it on (the lock screen does).  Only root and
 * members of the users group may connect.
 *
 * From fxtec-pro1x-guix (github.com/mlaparie/fxtec-pro1x-guix); the NixOS
 * port added the interrupt and finds the panel on any DRM card.
 *
 * The TA protocol (command ids, sizes, configuration, the enrol and verify
 * sequences) is moWerk's sailfish-fpd-mafp (sailfishos-pro1x-mainline,
 * packages/sailfish-fpd-mafp/src, GPL-3.0-or-later), rewritten in C without
 * Qt or the SailfishOS D-Bus API.  It needs the kernel fixes
 * pro1x-tzmem-bridge-errno, pro1x-qseecom-listener-rounds and
 * pro1x-qseecom-inout: without the last the replies cannot be read, without
 * the first two a store of several templates hangs the phone.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <linux/gpio.h>
#include <linux/input.h>
#include <linux/tee.h>

#ifndef TEE_IMPL_ID_QSEECOM
#define TEE_IMPL_ID_QSEECOM 5
#endif

#define SOCKET "/run/pro1x-fpd.sock"
#define NAMES "/var/lib/pro1x-fpd/names"
/* The panel's connector: card0 or card1, depending on what probed first. */
#define DPMS "/sys/class/drm/card*-DSI-1/dpms"

/* Where the TA keeps its templates, under qsee-supplicant's state directory. */
#define GROUP_PATH "/data/system/users/0/fpdata"
#define GROUP_ID 0

/* TLMM GPIO 108 powers the sensor ("microarray,gpio_pwr" in the stock DT). */
#define POWER_CHIP "500000.pinctrl"
#define POWER_LINE 108

#define BUF_SIZE 0x20000
#define ENROLL_SAMPLES 14       /* persist.vendor.fp.enroll.times */
#define POLL_MS 30              /* detect_touch, as the Android HAL's loops */
/*
 * Waiting for a finger to unlock.  Each detect_touch keeps a core busy about
 * 60 ms inside TrustZone (2 s of CPU in 3 s of polling at 30 ms, 2026-11-11):
 * at 250 ms that is about a fifth of a core, while the lock screen is lit.
 * The sensor's interrupt (TLMM 97) would avoid it; not tried yet.
 */
#define IDLE_POLL_MS 250
#define ENROLL_TIMEOUT 90       /* s without a finger before enrol gives up */
#define LIFT_TIMEOUT 5          /* s for the finger to leave */

enum {
	CMD_INIT = 0xc8,                /* [drv version][key len][key] */
	CMD_SERVICE_INIT = 0xc9,        /* g_config, 0x180 */
	CMD_SET_ACTIVE_GROUP = 0xca,    /* g_config with the path, 0x154 */
	CMD_PRE_ENROLL = 0xcd,
	CMD_ENROLL_START = 0xce,        /* 0x48: hw_auth_token_t, zero here */
	CMD_DO_ENROLL = 0xcf,           /* 0x16810 */
	CMD_ENROLL_FINISH = 0xd0,
	CMD_CANCEL = 0xd1,
	CMD_DETECT_TOUCH = 0xd2,        /* 0x16808, [mode] -> [touched] */
	CMD_TOUCH_ENERGY = 0xd3,        /* 0x3c0c */
	CMD_DO_VERIFY = 0xd5,           /* 0x16860 */
	CMD_UPDATE_AUTH_DATA = 0xd6,
	CMD_REMOVE = 0xd7,              /* 0x20: [fid] -> [.][err] */
	CMD_HAS_CALIBRATE = 0xd8,
	CMD_CALIBRATE = 0xd9,
	CMD_CALC_INTERRUPT_PARA = 0xda,
	CMD_REFRESH_CALILINE = 0xf6,    /* after the interrupt, before detect_touch */
	CMD_SLEEP = 0xdb,               /* [mode: 1 sleep, 2 reverse][.] -> [.][err] */
	CMD_RESET_INTERRUPT_PARA = 0xe1,
	CMD_ENUMERATE = 0xe2,           /* 0x20: -> [count][.][err][fids 0..4] */
	CMD_CHIP_ID = 0xef,             /* 0xc: -> [chip][err] */
};

static const uint32_t MA_DRV_VERSION = 0x4005;  /* madev's ioctl on Android */

struct shm {
	int id;
	uint8_t *va;
	size_t size;
};

static int tee_fd = -1;
static uint32_t session;
static struct shm req, rsp;
static int chip_id;
static int client = -1;         /* the connection being served */

static void logf_(const char *fmt, ...)
{
	va_list ap;
	time_t t = time(NULL);
	char ts[32];

	strftime(ts, sizeof(ts), "%F %T", localtime(&t));
	fprintf(stderr, "%s ", ts);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ── The TEE driver ─────────────────────────────────────────────────────── */

static int shm_alloc(size_t size, struct shm *out)
{
	struct tee_ioctl_shm_alloc_data data = { .size = size };
	int fd = ioctl(tee_fd, TEE_IOC_SHM_ALLOC, &data);

	if (fd < 0)
		return -1;
	out->va = mmap(NULL, data.size, PROT_READ | PROT_WRITE, MAP_SHARED,
		       fd, 0);
	close(fd);
	if (out->va == MAP_FAILED)
		return -1;
	out->id = data.id;
	out->size = data.size;
	memset(out->va, 0, data.size);
	return 0;
}

static void shm_free(struct shm *s)
{
	if (s->va && s->va != MAP_FAILED) {
		memset(s->va, 0, s->size);
		munmap(s->va, s->size);
	}
	s->va = NULL;
}

static int tee_open(void)
{
	for (int i = 0; i < 16; i++) {
		char path[32];
		struct tee_ioctl_version_data v = { 0 };
		int fd;

		snprintf(path, sizeof(path), "/dev/tee%d", i);
		fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (!ioctl(fd, TEE_IOC_VERSION, &v) &&
		    v.impl_id == TEE_IMPL_ID_QSEECOM) {
			tee_fd = fd;
			return 0;
		}
		close(fd);
	}
	errno = ENODEV;
	return -1;
}

/* A session to a loaded trusted app, by its name. */
static int open_session(const char *app, uint32_t *out)
{
	uint64_t storage[(sizeof(struct tee_ioctl_open_session_arg) +
			  sizeof(struct tee_ioctl_param) + 7) / 8] = { 0 };
	struct tee_ioctl_open_session_arg *arg = (void *)storage;
	struct tee_ioctl_buf_data bd = { (uintptr_t)storage, sizeof(storage) };
	struct shm name;
	int ret;

	if (shm_alloc(64, &name))
		return -1;
	strncpy((char *)name.va, app, 63);
	arg->num_params = 1;
	arg->params[0].attr = TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT;
	arg->params[0].b = 64;
	arg->params[0].c = name.id;
	ret = ioctl(tee_fd, TEE_IOC_OPEN_SESSION, &bd);
	shm_free(&name);
	if (ret)
		return -1;
	if (arg->ret) {
		errno = EIO;
		return -1;
	}
	*out = arg->session;
	return 0;
}

static void close_session(uint32_t s)
{
	struct tee_ioctl_close_session_arg arg = { .session = s };

	ioctl(tee_fd, TEE_IOC_CLOSE_SESSION, &arg);
}

/*
 * One send: a (INOUT) and b (OUTPUT).  The driver copies an INOUT request
 * back after the send (pro1x-qseecom-inout): the TA answers over it.
 */
static int invoke(uint32_t s, struct shm *a, size_t alen,
		  struct shm *b, size_t blen)
{
	uint64_t storage[(sizeof(struct tee_ioctl_invoke_arg) +
			  2 * sizeof(struct tee_ioctl_param) + 7) / 8] = { 0 };
	struct tee_ioctl_invoke_arg *arg = (void *)storage;
	struct tee_ioctl_buf_data bd = { (uintptr_t)storage, sizeof(storage) };

	arg->session = s;
	arg->num_params = 2;
	arg->params[0].attr = TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INOUT;
	arg->params[0].b = alen;
	arg->params[0].c = a->id;
	arg->params[1].attr = TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT;
	arg->params[1].b = blen;
	arg->params[1].c = b->id;
	if (ioctl(tee_fd, TEE_IOC_INVOKE, &bd))
		return -1;
	return (int)arg->ret;
}

/* ── The mafp TA ────────────────────────────────────────────────────────── */

/*
 * One command: [u32 cmd][u32 len][payload of len bytes, the first plen from
 * payload].  Returns the reply payload, in place, as words, valid until the
 * next command; NULL on a failed send.
 */
static const int32_t *command(uint32_t cmd, const void *payload, size_t plen,
			      size_t len)
{
	uint32_t l = len;
	int ret;

	if (len > BUF_SIZE - 8 || plen > len) {
		errno = EINVAL;
		return NULL;
	}
	memset(req.va, 0, len + 8);
	memcpy(req.va, &cmd, 4);
	memcpy(req.va + 4, &l, 4);
	if (payload && plen)
		memcpy(req.va + 8, payload, plen);
	ret = invoke(session, &req, BUF_SIZE, &rsp, BUF_SIZE);
	if (ret) {
		logf_("mafp command 0x%x failed: %d (%s)", cmd, ret,
		      ret < 0 ? strerror(errno) : "TEE");
		return NULL;
	}
	return (const int32_t *)(req.va + 8);
}

static const int32_t *simple(uint32_t cmd)
{
	int32_t z = 0;

	return command(cmd, &z, 4, 8);
}

/*
 * keymaster64 command 0x205 (GET_AUTH_TOKEN_KEY), type 2: a 64-byte request,
 * a 0x3c0 reply [status][offset][len][key].  INIT is seeded with this key.
 * It is never logged and wiped after use.
 */
static int keymaster_key(uint8_t *key, uint32_t *klen)
{
	struct shm a, b;
	uint32_t s, status, len;
	int ret = -1;

	if (shm_alloc(64, &a))
		return -1;
	if (shm_alloc(0x3c0, &b)) {
		shm_free(&a);
		return -1;
	}
	if (open_session("keymaster64", &s)) {
		logf_("no keymaster64 session: %s", strerror(errno));
		goto out;
	}
	((uint32_t *)a.va)[0] = 0x205;
	((uint32_t *)a.va)[1] = 2;
	ret = invoke(s, &a, 64, &b, 0x3c0);
	close_session(s);
	status = ((uint32_t *)b.va)[0];
	len = ((uint32_t *)b.va)[2];
	if (ret || status || !len || len > 0x400) {
		logf_("keymaster64 gave no key: ret %d status %d", ret,
		      (int32_t)status);
		ret = -1;
		goto out;
	}
	memcpy(key, b.va + 12, len);
	*klen = len;
	ret = 0;
out:
	shm_free(&a);
	shm_free(&b);
	return ret;
}

/* g_config as init_properties fills it for chip 0x24 from the stock defaults. */
static void fill_config(uint8_t *c)
{
	static const struct { uint16_t off; int32_t v; } f[] = {
		{ 0x000, 11 },          /* ro.build.version.release */
		{ 0x004, 1 },           /* enable.navi */
		{ 0x008, 1 },           /* return.auth */
		{ 0x00c, 1 },           /* duplicate.enroll */
		{ 0x010, 0 },           /* part.touch */
		{ 0x014, ENROLL_SAMPLES },
		{ 0x018, 2 },           /* match.time */
		{ 0x01c, 900 },         /* lpress.time, ms */
		{ 0x024, 0 },           /* energy.th; the TA sets 300 */
		{ 0x038, 2 },           /* enroll.fast.num */
		{ 0x138, 1 },           /* dirty_check */
		{ 0x13c, 0 },           /* save.debug.bmp */
		{ 0x144, 5 },           /* enroll_dupl_arae */
		{ 0x148, 80 },          /* part_touch_ratio */
	};

	for (size_t i = 0; i < sizeof(f) / sizeof(f[0]); i++)
		memcpy(c + f[i].off, &f[i].v, 4);
}

/* Hold the sensor's power line high for the daemon's lifetime. */
static int power_on(void)
{
	for (int i = 0; i < 16; i++) {
		char path[32];
		struct gpiochip_info info = { 0 };
		struct gpio_v2_line_request lr = { 0 };
		int fd, ret;

		snprintf(path, sizeof(path), "/dev/gpiochip%d", i);
		fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &info) ||
		    strcmp(info.label, POWER_CHIP) || POWER_LINE >= info.lines) {
			close(fd);
			continue;
		}
		lr.offsets[0] = POWER_LINE;
		lr.num_lines = 1;
		strcpy(lr.consumer, "pro1x-fpd");
		lr.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
		lr.config.num_attrs = 1;
		lr.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
		lr.config.attrs[0].attr.values = 1;
		lr.config.attrs[0].mask = 1;
		ret = ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &lr);
		close(fd);
		return ret ? -1 : lr.fd;        /* kept open: the line stays high */
	}
	errno = ENODEV;
	return -1;
}

/*
 * Bring the TA up as bio_init does: INIT (it must be the first command of
 * an app instance, or the instance dies), CHIP_ID, SERVICE_INIT,
 * SET_ACTIVE_GROUP.
 */
static int ta_start(void)
{
	uint8_t init[0x408] = { 0 }, cfg[0x180] = { 0 }, grp[0x154] = { 0 };
	uint32_t klen = 0, gid = GROUP_ID;
	const int32_t *r;

	if (tee_open()) {
		logf_("no QSEECOM TEE device (module qseecomtee?)");
		return -1;
	}
	if (shm_alloc(BUF_SIZE, &req) || shm_alloc(BUF_SIZE, &rsp)) {
		logf_("no shared memory: %s", strerror(errno));
		return -1;
	}
	if (keymaster_key(init + 8, &klen))
		return -1;
	if (open_session("mafp", &session)) {
		logf_("no mafp session (qsee-app-loader-mafp running?): %s",
		      strerror(errno));
		return -1;
	}
	memcpy(init, &MA_DRV_VERSION, 4);
	memcpy(init + 4, &klen, 4);
	r = command(CMD_INIT, init, sizeof(init), sizeof(init));
	memset(init, 0, sizeof(init));
	memset(req.va, 0, BUF_SIZE);
	if (!r)
		return -1;

	r = command(CMD_CHIP_ID, NULL, 0, 0xc);
	if (!r)
		return -1;
	chip_id = r[0];
	if (r[1]) {
		logf_("chip id read failed: %d (sensor power?)", r[1]);
		return -1;
	}

	fill_config(cfg);
	r = command(CMD_SERVICE_INIT, cfg, sizeof(cfg), sizeof(cfg));
	if (!r)
		return -1;
	if (r[0x150 / 4]) {     /* the TA's error word; its git tag follows */
		logf_("service init error %d", r[0x150 / 4]);
		return -1;
	}

	fill_config(grp);
	strncpy((char *)grp + 0x3c, GROUP_PATH, 0x7f);
	memcpy(grp + 0xbc, &gid, 4);
	r = command(CMD_SET_ACTIVE_GROUP, grp, sizeof(grp), sizeof(grp));
	if (!r)
		return -1;
	if (r[0x150 / 4]) {
		logf_("set active group error %d", r[0x150 / 4]);
		return -1;
	}
	return 0;
}

/* The template ids on file; -1 on a failed send. */
static int enumerate(uint32_t fids[5])
{
	const int32_t *r = simple(CMD_ENUMERATE);
	int n = 0;

	if (!r)
		return -1;
	for (int i = 0; i < r[0] && i < 5; i++)
		if (r[3 + i])
			fids[n++] = r[3 + i];
	return n;
}

/* While this file exists, each change of a detect_touch result is logged. */
#define TRACE "/run/pro1x-fpd.trace"

static int detect_touch(int mode)
{
	static int last[8] = { -99, -99, -99, -99, -99, -99, -99, -99 };
	int32_t m = mode;
	const int32_t *r = command(CMD_DETECT_TOUCH, &m, 4, 0x16808);
	int t = r ? r[0] : -1;

	if (mode >= 0 && mode < 8 && t != last[mode] && !access(TRACE, F_OK)) {
		logf_("trace %.3f mode %d: %d", now(), mode, t);
		last[mode] = t;
	}
	return t;
}

/* ── Names ──────────────────────────────────────────────────────────────── */

/* The name of a template, from NAMES ("ID NAME" lines), or "finger ID". */
static void name_of(uint32_t fid, char *out, size_t size)
{
	FILE *f = fopen(NAMES, "r");
	char line[256];

	snprintf(out, size, "finger %u", fid);
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		char *sp = strchr(line, ' ');

		if (!sp || strtoul(line, NULL, 10) != fid)
			continue;
		line[strcspn(line, "\n")] = 0;
		snprintf(out, size, "%s", sp + 1);
	}
	fclose(f);
}

/* Set (name non-NULL) or drop the name of a template. */
static int set_name(uint32_t fid, const char *name)
{
	FILE *in = fopen(NAMES, "r"), *out;
	char line[256];

	mkdir("/var/lib/pro1x-fpd", 0700);
	out = fopen(NAMES ".new", "w");
	if (!out) {
		if (in)
			fclose(in);
		return -1;
	}
	while (in && fgets(line, sizeof(line), in))
		if (strtoul(line, NULL, 10) != fid)
			fputs(line, out);
	if (in)
		fclose(in);
	if (name)
		fprintf(out, "%u %s\n", fid, name);
	if (fclose(out))
		return -1;
	return rename(NAMES ".new", NAMES);
}

/* ── Serving a client ───────────────────────────────────────────────────── */

static void say(const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n > (int)sizeof(buf) - 2)
		n = sizeof(buf) - 2;
	buf[n++] = '\n';
	if (client >= 0 && send(client, buf, n, MSG_NOSIGNAL) < 0) {
		close(client);
		client = -1;
	}
}

/*
 * Wait ms milliseconds; false once the client has gone (closed, or sent
 * anything: the only thing it may send during an operation is "cancel"),
 * and from then on.
 */
static int still_wanted(int ms)
{
	struct pollfd p = { .fd = client, .events = POLLIN };

	if (client < 0)
		return 0;
	if (poll(&p, 1, ms) > 0) {
		close(client);  /* the operation ends with it */
		client = -1;
		return 0;
	}
	return 1;
}

static int panel_on(void)
{
	char s[8] = "";
	glob_t g;
	int fd = -1;

	if (!glob(DPMS, 0, NULL, &g) && g.gl_pathc)
		fd = open(g.gl_pathv[0], O_RDONLY | O_CLOEXEC);
	globfree(&g);
	if (fd < 0)
		return 1;
	if (read(fd, s, sizeof(s) - 1) < 0)
		s[0] = 0;
	close(fd);
	return strncmp(s, "Off", 3) != 0;
}

/*
 * Raise the sensor's interrupt (TLMM 97) while a finger is on it, as
 * Android's libfprint does in authenticate_work before it waits in madev:
 * detect_touch(0) until no finger, then ma_tac_sleep (0xDB, mode 1).  It
 * stays armed through any number of touches; reading the sensor again does
 * not disarm it.  The kernel reports the line as KEY_WAKEUP (patch
 * pro1x-fingerprint-key), so a touch on a locked phone wakes it and turns
 * the screen on.
 */
static void arm_interrupt(void)
{
	uint32_t m[2] = { 1, 0 };
	const int32_t *r;

	for (int k = 0; k < 40 && detect_touch(0) > 0; k++)
		usleep(POLL_MS * 1000);
	r = command(CMD_SLEEP, m, sizeof(m), 8);
	if (!r || r[1])
		logf_("arming the interrupt failed: %d", r ? r[1] : -1);
}

/* Poll detect_touch(mode) until it reports `touched`: 1, 0 on a timeout or a gone client, -1 on a failure. */
static int wait_touch(int mode, int touched, double seconds, int ms)
{
	double end = now() + seconds;

	while (now() < end) {
		int t = detect_touch(mode);

		if (t < 0)
			return -1;
		if ((t != 0) == touched)
			return 1;
		if (!still_wanted(ms))
			return 0;
	}
	return 0;
}

/*
 * Identify's wait for a finger: as wait_touch(0, 1, ...), but only while the
 * panel is lit, so that once it goes off the sensor is left to its
 * interrupt (reading it would take the touch the wake key is for).
 */
static int wait_touch_lit(double seconds)
{
	double end = now() + seconds;

	while (now() < end && panel_on()) {
		int t = detect_touch(0);

		if (t < 0)
			return -1;
		if (t)
			return 1;
		if (!still_wanted(IDLE_POLL_MS))
			return 0;
	}
	return 0;
}

static void do_list(void)
{
	uint32_t fids[5];
	char name[200];
	int n = enumerate(fids);

	if (n < 0) {
		say("error the sensor did not answer");
		return;
	}
	for (int i = 0; i < n; i++) {
		name_of(fids[i], name, sizeof(name));
		say("finger %u %s", fids[i], name);
	}
	say("ok");
}

/* What enroll_work in the Android HAL logs for a do_enroll status. */
static const char *enrol_reason(int status)
{
	static char other[32];

	switch (status) {
	case -2987: return "partial touch, cover the whole sensor";
	case -2988: return "same area as before, move the finger a little";
	case -2989: return "this finger is enrolled already";
	case -3187: return "finger dirty";
	case -3189: return "image not readable";
	}
	snprintf(other, sizeof(other), "code %d", status);
	return other;
}

/*
 * As enroll_work in the Android HAL: calibrate if asked, pre_enroll,
 * enroll_start with a zero auth token (this TA accepts it), then per sample
 * a touch, detectTouch_getEnergy, do_enroll and the lift; enroll_finish
 * after ENROLL_SAMPLES accepted samples.  The new id is the one enumerate
 * shows that was not there before.
 */
static void do_enroll(const char *name)
{
	uint32_t before[5], after[5], fid = 0;
	uint8_t params[0x48] = { 0 };
	int nb = enumerate(before), na, accepted = 0, tries = 0;
	const int32_t *r;

	if (nb < 0) {
		say("error the sensor did not answer");
		return;
	}
	if (nb >= 5) {
		say("error five fingers on file already; remove one first");
		return;
	}
	r = simple(CMD_HAS_CALIBRATE);
	if (r && r[0])
		simple(CMD_CALIBRATE);
	simple(CMD_PRE_ENROLL);
	r = command(CMD_ENROLL_START, params, sizeof(params), sizeof(params));
	if (!r || r[1]) {
		say("error enrolment refused (%d)", r ? r[1] : -1);
		return;
	}
	while (accepted < ENROLL_SAMPLES) {
		uint8_t in[0x14] = { 0 };
		uint32_t ts = time(NULL);
		int t;

		say("touch");
		t = wait_touch(1, 1, ENROLL_TIMEOUT, POLL_MS);
		if (t <= 0 || client < 0) {
			simple(CMD_CANCEL);
			simple(CMD_ENROLL_FINISH);
			say(t < 0 ? "error the sensor did not answer"
				  : "error no finger, enrolment cancelled");
			return;
		}
		memcpy(in + 0x10, &ts, 4);
		r = command(CMD_DO_ENROLL, in, sizeof(in), 0x16810);
		tries++;
		if (!r) {
			say("error the sensor did not answer");
			return;
		}
		if (!r[1] && !r[2]) {
			accepted++;
			say("sample %d/%d", accepted, ENROLL_SAMPLES);
		} else {
			logf_("enrol sample %d: status %d err %d", tries, r[1], r[2]);
			say("retry %s", enrol_reason(r[2] ? r[2] : r[1]));
		}
		say("lift");
		wait_touch(1, 0, LIFT_TIMEOUT, POLL_MS);
		if (client < 0)
			break;
	}
	if (accepted < ENROLL_SAMPLES) {
		simple(CMD_CANCEL);
		simple(CMD_ENROLL_FINISH);
		return;
	}
	simple(CMD_ENROLL_FINISH);
	na = enumerate(after);
	for (int i = 0; i < na; i++) {
		int seen = 0;

		for (int j = 0; j < nb; j++)
			seen |= after[i] == before[j];
		if (!seen)
			fid = after[i];
	}
	logf_("enrolled %u after %d samples", fid, tries);
	if (!fid) {
		say("error no new template after the enrolment");
		return;
	}
	if (name && *name)
		set_name(fid, name);
	say("enrolled %u", fid);
}

/*
 * As tap_work_active: reset and compute the interrupt parameters,
 * enumerate, update_authenticate_data, then per attempt a touch (mode 0),
 * the chip 0x24 capture (mode 4, up to five times) and do_verify.  Reply:
 * [0] template count, [1] matched id (0 for none), [3] status, [4] err.
 * Runs until a match or the client goes; waits without reading the sensor
 * while the panel is off.
 */
/*
 * The sensor's interrupt as an input device (patch pro1x-fingerprint-key):
 * a touch while the panel is off is read without turning it on.
 */
static int key_fd = -1;

static void open_finger_key(void)
{
	char path[32], name[64];

	for (int i = 0; key_fd < 0 && i < 32; i++) {
		int fd;

		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) > 0 &&
		    !strcmp(name, "Fingerprint"))
			key_fd = fd;
		else
			close(fd);
	}
}

/*
 * While the panel is off: wait up to ms for the client to go (0) or a
 * finger on the sensor (2); 1 for neither.
 */
static int wait_dark(int ms)
{
	struct pollfd p[2] = {
		{ .fd = client, .events = POLLIN },
		{ .fd = key_fd, .events = POLLIN },
	};
	struct input_event ev;
	int down = 0;

	if (client < 0)
		return 0;
	if (poll(p, key_fd >= 0 ? 2 : 1, ms) <= 0)
		return 1;
	if (p[0].revents) {
		close(client);  /* the operation ends with it */
		client = -1;
		return 0;
	}
	while (read(key_fd, &ev, sizeof(ev)) == sizeof(ev))
		if (ev.type == EV_KEY && ev.code == KEY_WAKEUP && ev.value == 1)
			down = 1;
	return down ? 2 : 1;
}

/*
 * No suspend while a dark touch is read (wm-suspend's wakeup_count waits):
 * 1 holds it, 0 lets go, 2 lets go in 3 s (after a match, so that the lock
 * screen turns the panel on before anything can suspend again).
 */
static void stay_awake(int on)
{
	static int held;
	int fd;

	if (on == held || (on == 0 && held == 2))
		return;
	fd = open(on ? "/sys/power/wake_lock" : "/sys/power/wake_unlock",
		  O_WRONLY | O_CLOEXEC);
	if (fd >= 0) {
		/* With a timeout, in case this process dies holding it */
		const char *s = on == 2 ? "pro1x-fpd 3000000000" :
				on ? "pro1x-fpd 8000000000" : "pro1x-fpd";

		if (write(fd, s, strlen(s)) < 0)
			logf_("wake lock: %s", strerror(errno));
		close(fd);
	}
	held = on;
}

static void identify_loop(void)
{
	uint32_t fids[5], retry = 1;
	char name[200];
	const int32_t *r;
	int n = enumerate(fids);

	if (n < 0) {
		say("error the sensor did not answer");
		return;
	}
	if (n == 0) {
		say("error no finger enrolled");
		return;
	}
	simple(CMD_RESET_INTERRUPT_PARA);
	simple(CMD_CALC_INTERRUPT_PARA);
	r = command(CMD_UPDATE_AUTH_DATA, NULL, 0, 4);
	if (!r) {
		say("error the sensor did not answer");
		return;
	}
	for (;;) {
		uint8_t in[0x60] = { 0 };
		uint32_t ts;
		int got = 0, t, dark = 0;

		stay_awake(0);
		if (!panel_on()) {
			arm_interrupt();
			open_finger_key();
			for (;;) {
				int w = wait_dark(1000);

				if (!w)
					return;
				if (panel_on())
					break;
				if (w == 2) {
					dark = 1;
					stay_awake(1);
					break;
				}
			}
		}
		/*
		 * A dark touch: the finger is on the sensor now, or soon gone.
		 * Android's authenticate_work refreshes the calibration line
		 * after the interrupt, then reads.
		 */
		if (dark)
			simple(CMD_REFRESH_CALILINE);
		t = dark ? wait_touch(0, 1, 1, POLL_MS) : wait_touch_lit(2);
		if (dark)
			logf_("dark touch: %s", t > 0 ? "finger" : t ? "error" : "gone");
		if (t < 0) {
			say("error the sensor did not answer");
			return;
		}
		if (client < 0)
			return;
		if (t == 0)
			continue;
		for (int k = 0; k < 5 && !got; k++)
			got = detect_touch(4) == 1;
		ts = time(NULL);
		memcpy(in + 0xc, &retry, 4);
		memcpy(in + 0x10, &ts, 4);
		r = command(CMD_DO_VERIFY, in, sizeof(in), 0x16860);
		if (!r) {
			say("error the sensor did not answer");
			return;
		}
		logf_("verify: fid %d status %d err %d capture %d",
		      r[1], r[3], r[4], got);
		if (r[1]) {
			uint32_t fid = r[1];

			name_of(fid, name, sizeof(name));
			if (dark)
				stay_awake(2);
			say("match %u %s", fid, name);
			return;
		}
		say("nomatch");
		retry++;
		if (wait_touch(0, 0, LIFT_TIMEOUT, POLL_MS) < 0 || client < 0)
			return;
	}
}

static void do_identify(void)
{
	identify_loop();
	stay_awake(0);
}

/*
 * A test of the touch detection: for SECONDS, every POLL_MS, the readings
 * WHAT names (0 and 1: detect_touch in that mode; e: get_energy, its energy
 * and error words), one line per round to the client.  First, in the order
 * given: k calibrate, r reset and i calc the interrupt parameters.
 */
static void do_probe(const char *arg)
{
	double seconds = arg ? atof(arg) : 10, end;
	const char *what = arg && strchr(arg, ' ') ? strchr(arg, ' ') + 1 : "1e";

	if (seconds <= 0 || seconds > 120)
		seconds = 10;
	for (const char *w = what; *w; w++) {
		const int32_t *r = NULL;

		if (*w == 'k')
			r = simple(CMD_CALIBRATE);
		else if (*w == 'r')
			r = simple(CMD_RESET_INTERRUPT_PARA);
		else if (*w == 'i')
			r = simple(CMD_CALC_INTERRUPT_PARA);
		else
			continue;
		say("setup %c: %d %d", *w, r ? r[0] : -1, r ? r[1] : -1);
	}
	end = now() + seconds;
	while (now() < end) {
		char buf[200];
		int n = snprintf(buf, sizeof(buf), "%.3f", now());

		for (const char *w = what; *w && n < (int)sizeof(buf) - 40; w++) {
			const int32_t *r;

			if (*w == '0' || *w == '1') {
				n += snprintf(buf + n, sizeof(buf) - n, " t%c %d", *w,
					      detect_touch(*w - '0'));
			} else if (*w == 'e') {
				r = command(CMD_TOUCH_ENERGY, NULL, 0, 0x3c0c);
				n += snprintf(buf + n, sizeof(buf) - n, " e %d %d",
					      r ? r[1] : -1, r ? r[2] : -1);
			}
		}
		say("%s", buf);
		if (!still_wanted(POLL_MS))
			return;
	}
	say("ok");
}

static void do_remove(uint32_t fid)
{
	int32_t f = fid;
	const int32_t *r = command(CMD_REMOVE, &f, 4, 0x20);

	if (!r || r[1]) {
		say("error could not remove %u", fid);
		return;
	}
	set_name(fid, NULL);
	logf_("removed %u", fid);
	say("ok");
}

static int allowed(int fd)
{
	struct ucred cr;
	socklen_t len = sizeof(cr);
	struct group *g;
	gid_t groups[64];
	int n = 64;
	struct passwd *pw;

	if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len))
		return 0;
	if (cr.uid == 0)
		return 1;
	g = getgrnam("users");
	if (!g)
		return 0;
	if (cr.gid == g->gr_gid)
		return 1;
	pw = getpwuid(cr.uid);
	if (!pw || getgrouplist(pw->pw_name, pw->pw_gid, groups, &n) < 0)
		return 0;
	for (int i = 0; i < n; i++)
		if (groups[i] == g->gr_gid)
			return 1;
	return 0;
}

static void serve(int fd)
{
	char line[256];
	ssize_t n;
	char *arg;

	client = fd;
	n = recv(fd, line, sizeof(line) - 1, 0);
	if (n <= 0)
		goto out;
	line[n] = 0;
	line[strcspn(line, "\r\n")] = 0;
	arg = strchr(line, ' ');
	if (arg)
		*arg++ = 0;
	logf_("request: %s", line);
	if (!strcmp(line, "status")) {
		uint32_t fids[5];
		int k = enumerate(fids);

		if (k < 0)
			say("error the sensor did not answer");
		else
			say("ready chip 0x%x fingers %d", chip_id, k);
	} else if (!strcmp(line, "list")) {
		do_list();
	} else if (!strcmp(line, "identify")) {
		do_identify();
	} else if (!strcmp(line, "enroll")) {
		do_enroll(arg);
	} else if (!strcmp(line, "probe")) {
		do_probe(arg);
	} else if (!strcmp(line, "remove") && arg) {
		do_remove(strtoul(arg, NULL, 10));
	} else if (!strcmp(line, "rename") && arg && strchr(arg, ' ')) {
		uint32_t fid = strtoul(arg, NULL, 10);

		if (set_name(fid, strchr(arg, ' ') + 1))
			say("error could not save the name");
		else
			say("ok");
	} else {
		say("error unknown request: %s", line);
	}
out:
	if (client >= 0)
		close(client);
	client = -1;
}

/* Stopped (herd stop): no socket left behind, which would tell the lock
 * screen and quick actions that the daemon runs. */
static void on_term(int sig)
{
	(void)sig;
	unlink(SOCKET);
	_exit(0);
}

static int daemon_main(void)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	int power, lfd;

	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);
	power = power_on();
	if (power < 0) {
		logf_("cannot hold the sensor's power line: %s", strerror(errno));
		return 1;
	}
	if (ta_start())
		return 1;
	logf_("ready, chip id 0x%x", chip_id);

	strcpy(sa.sun_path, SOCKET);
	unlink(SOCKET);
	lfd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (lfd < 0 || bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) ||
	    chmod(SOCKET, 0666) || listen(lfd, 4)) {
		logf_("socket %s: %s", SOCKET, strerror(errno));
		return 1;
	}
	for (;;) {
		int fd = accept4(lfd, NULL, NULL, SOCK_CLOEXEC);

		if (fd < 0)
			continue;
		if (!allowed(fd)) {
			client = fd;
			say("error not allowed");
			close(fd);
			client = -1;
			continue;
		}
		serve(fd);
	}
}

/* ── The client ─────────────────────────────────────────────────────────── */

static int client_main(int argc, char **argv)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	char line[256] = "", buf[512];
	int fd, status = 1;
	FILE *f;

	for (int i = 1; i < argc; i++) {
		if (i > 1)
			strncat(line, " ", sizeof(line) - strlen(line) - 1);
		strncat(line, argv[i], sizeof(line) - strlen(line) - 2);
	}
	strcat(line, "\n");
	strcpy(sa.sun_path, SOCKET);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof(sa))) {
		fprintf(stderr, "pro1x-fpd: not running (%s)\n", strerror(errno));
		return 2;
	}
	if (write(fd, line, strlen(line)) < 0)
		return 2;
	f = fdopen(fd, "r");
	while (fgets(buf, sizeof(buf), f)) {
		fputs(buf, stdout);
		fflush(stdout);
		if (!strncmp(buf, "ok", 2) || !strncmp(buf, "match ", 6) ||
		    !strncmp(buf, "enrolled ", 9) || !strncmp(buf, "ready ", 6))
			status = 0;
	}
	return status;
}

int main(int argc, char **argv)
{
	if (argc < 2 || !strcmp(argv[1], "--help")) {
		fprintf(stderr, "usage: pro1x-fpd --daemon | status | list | "
			"identify | enroll NAME | remove ID | rename ID NAME\n");
		return 2;
	}
	if (!strcmp(argv[1], "--daemon"))
		return daemon_main();
	return client_main(argc, argv);
}
