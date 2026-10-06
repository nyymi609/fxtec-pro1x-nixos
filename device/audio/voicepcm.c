/* pro1x-voicepcm: keep the VoiceMMode1 hostless PCM open and started. */
#include <alsa/asoundlib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

static int find_pcm(const char *want, char *out, size_t len)
{
	int card = -1;

	while (snd_card_next(&card) >= 0 && card >= 0) {
		char ctl[32];
		snd_ctl_t *h;
		int dev = -1;

		snprintf(ctl, sizeof(ctl), "hw:%d", card);
		if (want && *want) {
			char *end;
			long idx = strtol(want, &end, 10);
			char *name = NULL;

			if (*end == 0 ? idx != card :
			    (snd_card_get_name(card, &name) < 0 ||
			     !strstr(name, want))) {
				free(name);
				continue;
			}
			free(name);
		}
		if (snd_ctl_open(&h, ctl, 0) < 0)
			continue;
		while (snd_ctl_pcm_next_device(h, &dev) >= 0 && dev >= 0) {
			snd_pcm_info_t *info;

			snd_pcm_info_alloca(&info);
			snd_pcm_info_set_device(info, dev);
			snd_pcm_info_set_subdevice(info, 0);
			snd_pcm_info_set_stream(info, SND_PCM_STREAM_PLAYBACK);
			if (snd_ctl_pcm_info(h, info) < 0)
				continue;
			if (strstr(snd_pcm_info_get_name(info), "VoiceMMode1") ||
			    strstr(snd_pcm_info_get_id(info), "VoiceMMode1")) {
				snprintf(out, len, "hw:%d,%d", card, dev);
				snd_ctl_close(h);
				return 0;
			}
		}
		snd_ctl_close(h);
	}
	return -1;
}

static snd_pcm_t *open_start(const char *dev, snd_pcm_stream_t dir)
{
	snd_pcm_t *pcm;
	snd_pcm_hw_params_t *hw;
	int err;

	err = snd_pcm_open(&pcm, dev, dir, 0);
	if (err < 0) {
		fprintf(stderr, "open %s (%s): %s\n", dev,
			dir == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture",
			snd_strerror(err));
		return NULL;
	}
	snd_pcm_hw_params_alloca(&hw);
	snd_pcm_hw_params_any(pcm, hw);
	snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
	snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE);
	snd_pcm_hw_params_set_channels(pcm, hw, 1);
	snd_pcm_hw_params_set_rate(pcm, hw, 8000, 0);
	err = snd_pcm_hw_params(pcm, hw);
	if (err < 0) {
		fprintf(stderr, "hw_params %s: %s\n", dev, snd_strerror(err));
		goto fail;
	}
	err = snd_pcm_prepare(pcm);
	if (err < 0) {
		fprintf(stderr, "prepare %s: %s\n", dev, snd_strerror(err));
		goto fail;
	}
	if (dir == SND_PCM_STREAM_PLAYBACK) {
		/* The kernel refuses to start a playback stream with an empty
		 * buffer (-EPIPE), so queue some silence first. */
		snd_pcm_uframes_t n = 0;
		static const short zeros[1024];

		snd_pcm_hw_params_get_buffer_size(hw, &n);
		if (n > 1024)
			n = 1024;
		if (n)
			snd_pcm_writei(pcm, zeros, n);
	}
	/* The q6voice driver starts the DSP voice session when the stream is
	 * opened (startup), once both directions are open; there is no data
	 * flow to trigger, so a start error is only informational. */
	err = snd_pcm_start(pcm);
	if (err < 0)
		fprintf(stderr, "note: start %s (%s): %s (state %s) - ignored\n", dev,
			dir == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture",
			snd_strerror(err), snd_pcm_state_name(snd_pcm_state(pcm)));
	else
		fprintf(stderr, "%s stream started\n",
			dir == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture");
	return pcm;
fail:
	snd_pcm_close(pcm);
	return NULL;
}

int main(int argc, char **argv)
{
	char dev[32];
	snd_pcm_t *pb, *cap;
	int tries;

	signal(SIGTERM, on_sig);
	signal(SIGINT, on_sig);

	for (tries = 0; tries < 30; tries++) {
		if (!find_pcm(argc > 1 ? argv[1] : NULL, dev, sizeof(dev)))
			break;
		sleep(1);
	}
	if (tries == 30) {
		fprintf(stderr, "no VoiceMMode1 PCM found (is q6voice loaded?)\n");
		return 1;
	}
	fprintf(stderr, "using %s\n", dev);

	pb = open_start(dev, SND_PCM_STREAM_PLAYBACK);
	cap = open_start(dev, SND_PCM_STREAM_CAPTURE);
	if (!pb && !cap)
		return 1;

	while (!stop)
		pause();

	if (pb) { snd_pcm_drop(pb); snd_pcm_close(pb); }
	if (cap) { snd_pcm_drop(cap); snd_pcm_close(cap); }
	return 0;
}
