/*
 * pam_pro1x_fpd: a finger on the Pro1X's reader instead of the password,
 * through pro1x-fpd (one identify on /run/pro1x-fpd.sock), like pam_fprintd
 * elsewhere.
 *
 *   auth sufficient pam_pro1x_fpd.so [timeout=SECONDS]
 *
 * PAM_SUCCESS on a match. Ctrl+C, the timeout (10 s) or no daemon give
 * PAM_AUTHINFO_UNAVAIL, so the next rule (the password) takes over.
 *
 * In the program's own process, as pam_fprintd: pam_exec runs its command
 * in a session of its own, which the terminal's ctrl+c never reaches. SIGINT
 * is blocked while waiting and read from a signalfd, as pam_fprintd does it;
 * sudo also ignores it then, and an ignored signal is dropped before a
 * signalfd sees it, so meanwhile it has a handler that never runs.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <security/pam_ext.h>
#include <security/pam_modules.h>

#define SOCKET "/run/pro1x-fpd.sock"

static void no_op(int sig)
{
	(void)sig;
}

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int connect_fpd(void)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (fd < 0)
		return -1;
	strncpy(sa.sun_path, SOCKET, sizeof(sa.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

/*
 * Lines from pro1x-fpd until "match ..." (1), the end of the connection, an
 * error line, ctrl+c or the timeout (0).
 */
static int identify(pam_handle_t *pamh, int fd, int sfd, long end)
{
	char buf[512];
	size_t len = 0;

	for (;;) {
		struct pollfd p[2] = { { fd, POLLIN, 0 }, { sfd, POLLIN, 0 } };
		long left = end - now_ms();
		int n;

		if (left <= 0)
			return 0;
		n = poll(p, sfd >= 0 ? 2 : 1, (int)left);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return 0;
		}
		if (n == 0)
			return 0;
		if (sfd >= 0 && (p[1].revents & POLLIN)) {
			struct signalfd_siginfo si;

			if (read(sfd, &si, sizeof(si)) > 0)
				pam_syslog(pamh, LOG_DEBUG, "signal %u, to the password", si.ssi_signo);
			return 0;
		}
		if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
			ssize_t r = read(fd, buf + len, sizeof(buf) - 1 - len);
			char *line, *nl;

			if (r <= 0)
				return 0;
			len += (size_t)r;
			buf[len] = '\0';
			line = buf;
			while ((nl = strchr(line, '\n'))) {
				*nl = '\0';
				if (!strncmp(line, "match ", 6))
					return 1;
				if (!strcmp(line, "nomatch"))
					pam_info(pamh, "Not recognised, try again");
				else if (!strncmp(line, "error", 5)) {
					pam_syslog(pamh, LOG_WARNING, "pro1x-fpd: %s", line);
					return 0;
				}
				line = nl + 1;
			}
			len = strlen(line);
			memmove(buf, line, len + 1);
			if (len == sizeof(buf) - 1)
				len = 0;
		}
	}
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	struct sigaction act = { .sa_handler = no_op }, oldact;
	sigset_t sigint, old;
	int timeout = 10, fd, sfd, matched;

	(void)flags;
	for (int i = 0; i < argc; i++)
		if (!strncmp(argv[i], "timeout=", 8))
			timeout = atoi(argv[i] + 8);
	if (timeout <= 0)
		timeout = 10;

	fd = connect_fpd();
	if (fd < 0)
		return PAM_AUTHINFO_UNAVAIL;
	if (write(fd, "identify\n", 9) != 9) {
		close(fd);
		return PAM_AUTHINFO_UNAVAIL;
	}

	/* SIGINT as a readable fd while waiting: blocked (as sudo has it
	 * anyway), and not ignored, so that it stays pending */
	sigemptyset(&sigint);
	sigaddset(&sigint, SIGINT);
	pthread_sigmask(SIG_BLOCK, &sigint, &old);
	sigemptyset(&act.sa_mask);
	sigaction(SIGINT, &act, &oldact);
	sfd = signalfd(-1, &sigint, SFD_NONBLOCK | SFD_CLOEXEC);

	pam_info(pamh, "Touch the fingerprint sensor (ctrl+c or %d s for the password)", timeout);
	matched = identify(pamh, fd, sfd, now_ms() + timeout * 1000L);

	/* Gone: pro1x-fpd ends the identify */
	close(fd);
	if (sfd >= 0)
		close(sfd);
	/* A ctrl+c taken here mustn't reach the program after it is unblocked */
	if (!matched) {
		struct timespec zero = { 0, 0 };

		while (sigtimedwait(&sigint, NULL, &zero) > 0)
			;
	}
	sigaction(SIGINT, &oldact, NULL);
	pthread_sigmask(SIG_SETMASK, &old, NULL);

	return matched ? PAM_SUCCESS : PAM_AUTHINFO_UNAVAIL;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_SUCCESS;
}
