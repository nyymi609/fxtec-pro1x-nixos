# moWerk's 7.3 series against ours: what overlaps, whose way is better

Review for the author (2026-11-02), before deciding what this branch keeps.
Sources: his `kernel/patches-7.3/` and `kernel/HANDOVER.md`
(github.com/moWerk/sailfishos-pro1x-mainline), our `device/kernel/patches/`
and userspace (`device/sway/pro1x-sleep` and friends).  Labels: **same**
(identical code), **his better**, **ours better**, **complementary**,
**his only**, **ours only**.  Device claims from his notes are *reported*
(his phone, SailfishOS), not verified here.

## Identical: nothing to choose

Compared hunk by hunk (added and removed code lines, comments aside):

| ours (7.1) | his | origin |
|---|---|---|
| fastrpc-wake | 0033 | Lenovo TB-J606L port (haltia-de), patch 0015 |
| fastrpc-resume-interrupted | 0034 | TB-J606L port, patch 0016 |
| panel-display-off | 0023 | his |
| imx582-1080p | 0014 | his |
| dw9800-soft | 0015 | his |
| NixOS device series (touch, dsi, audio, …) | 0001-0011 | nyymi609's NixOS port, rebased by him |

## Charging: his better

- **Ours:** `charge-control` adds a `charge_enable` module parameter; a
  userspace service polls once a minute and flips it (stop at the limit,
  resume below).
- **His:** a `charging_enabled` attribute (0017) plus the reason our limit
  overshoots: the phone suspends while charging and nobody polls. 0040
  holds a wakeup source while USB is in and charging is on, dropped when
  charging stops; 0048 refines it for host ports; 0052 re-runs charger
  detection once.
- **Status on this branch:** his taken; our userspace now drives either
  switch (3e9e263).  Our overshoot to 91 % (2026-11-02) fits his
  explanation and his battery-estimate fixes (below).

## ADSP and suspend: complementary, his adds the missing half

- **Ours:** the fastrpc pair (identical to his) plus a userspace fallback
  in `pro1x-sleep`: restart a crashed ADSP once, then hexagonrpcd and the
  sensor services; restart iio-sensor-proxy after resume.
- **His:** additionally 0032, the SMP2P sleep-state driver: tells the
  ADSP's sensor framework that the AP sleeps (and lets it wake the AP), so
  it stops talking to a suspended system. That is the cause our fallback
  only cleans up after.  He reports 100+ suspends without an ADSP crash.
- **Keep both** for now; drop our restarts once 0032 proves itself here.

## Wake sources: different approaches, each with something the other lacks

- **Ours** (userspace policy, `pro1x-sleep`): turns off wakeups that end a
  suspend for nothing, while asleep only:
  - the Bluetooth UART;
  - the modem's data path (IPA);
  - gpio-keys (the keyboard slide);
  
  plus:
  - an RTC alarm for Clocks;
  - a wake-cause log with retries;
  - the cyan LED;
  - kernel-side modem wake **v4**: QRTR data for user space wakes the
    system, filtered by source port to voice and SMS (calls and SMS wake
    the phone, network chatter does not).
- **His** (kernel): wakes *added*:
  - touch keeps scanning in suspend, so double-tap wakes it (0035);
  - USB-C cable attach (0046, 0047);
  - charger stay-awake (0040).
  
  No modem call wake in his series: SailfishOS handles calls differently.
- **Verdict:** ours only for calls and SMS (keep modem wake v4) and for the
  noise filtering (IPA, UART, slide). His only for double-tap from suspend
  (our `pro1x-doubletap` wakes the panel only when the phone is awake) and
  cable attach.  0035 costs some power (touch scanning while asleep):
  measure before keeping it on.

## Deep sleep: his only

0037 (RPM master stats), 0038-0039/0043 (MPM, PSCI init), 0041 (USB GDSC
retention), 0045 (cluster idle-state parameters: 44 M firmware rejections
per boot, the suspend loop spinning), 0049 (vMPM wake timer), 0053 (panel
enable with the panel: 73-79 to 49 mA), 0054 (LPASS vote handle: the DSP
could not sleep), 0055 (UFS lane clocks), 0057 (dispcc XO vote).  We have
none of it; this is why the branch exists.  0050/0051/0056 (system power
domain, the full deep sleep) are experimental for him and left out here.

## Smaller fixes: his only

Modem crash at boot (0029, qrtr HELLO); battery estimate after a charge
and at resume (0036, 0044); amplifier clicks (0022, 0026); panel flash at
wake and brightness errors (0030, 0042); UFS throughput (0024); ath10k log
noise (0031); GPU bandwidth vote (0021); Venus encoder (0013).  All
welcome; none conflicts with ours.

## Ours only, kept on top

- modem wake v4 (QRTR wakeup with port filter);
- panelgap and dpugap (module parameters, off by default; NixOS port).

Dropped: q6v5-handover (7.3 no longer logs the repeats) and charge-control
(replaced by his attribute).

## Left out from his, on purpose

- **0012 sfos-dt:**
  - Fn as Right Alt and the slide switch inverted: SailfishOS-only; our
    keyd and slider helpers expect the hardware's own;
  - its keyboard-backlight inversion, which 0028 undoes again.
- **0050, 0051, 0056:** experimental.

## Suggested order once 7.3 boots here

1. The base as built (CI run 41388196979): modem, calls, audio, camera,
   Wi-Fi, Bluetooth, USB networking.
2. Suspend with 0032 in: ADSP crashes gone?  Then our ADSP restarts can go.
3. RPM master stats: which master still blocks XO shutdown.
4. Measure 0035 (double-tap from suspend) for its power cost.
5. Then 0050/0051/0056 for the real deep sleep.
