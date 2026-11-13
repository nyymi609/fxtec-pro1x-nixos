# Kernel 7.3 series (branch `kernel-7.3`)

Patches for mainline v7.3 (kernel.org tarball), applied in file-name order,
then ours from `../patches/` (see `modules/fxtec-pro1x/packages/kernel.scm`).

Origin: moWerk's SailfishOS mainline port of the Pro1-X,
github.com/moWerk/sailfishos-pro1x-mainline, `kernel/patches-7.3/`, copied
on 2026-11-02 (GPL-2.0, as the kernel), unchanged but for one comment:
0010 writes the fixed, locally administered Bluetooth address of its
local-bd-address with spaces instead of colons (the repository's privacy
hook refuses MAC-shaped strings; the value is the same on every phone,
the DT line under it unchanged).  What each patch does and
its upstream status: that repository's `kernel/HANDOVER.md`.  0001-0011 are
the NixOS port's device patches (nyymi609/fxtec-pro1x-nixos) rebased by him;
0029, 0032-0034, 0038 come from the Lenovo TB-J606L port (haltia-de).

Left out:
- 0012 sfos-dt: SailfishOS-only (Fn as KEY_RIGHTALT, the slide switch
  inverted for mce), which our keyd and slider helpers do not expect; and
- 0028, which only undoes 0012's keyboard backlight inversion;
- 0035 goodix touch scanning through suspend (double-tap wakes it from
  sleep): not wanted (author, 2026-11-02);
- 0058-0062 (newer than the copy): his modem wake (every packet from the
  modem wakes the system) and Wi-Fi wake-on-WLAN fixes.  Ours,
  qrtr-modem-wake, wakes only on the ports config.scm's wake-on lists; his
  would change the wake triggers (author, 2026-11-07: they stay as they are).

Added on 2026-11-07 from his tree: 0050 (a system power domain above the
clusters, under the MPM: the SoC reaches RPM vmin in suspend), 0051 (the
SPMI interrupt, so the power key, RTC and USB-C, through the MPM, which 0050
needs) and 0056 (UFS powered down in suspend, else hibern8 exit crashed
after a system-level sleep).  In his daily kernel since 2026-11-02; with
0054-0057, he measured 37-45 mA in suspend against 56-60 without the system
domain (his notes/sleep.md).  Open on ours: whether qrtr-modem-wake still
wakes the phone for calls and SMS with 0050 (his notes: the modem's glink
interrupt is still handled in s2idle, but reports no wakeup itself).

Ours on top (`../patches/`): panelgap, dpugap (NixOS port, module
parameters, off by default), qrtr-modem-wake (v4).  Dropped from our 7.1
list: q6v5-handover (7.3 no longer logs the repeated handover),
charge-control (his charging_enabled attribute replaces it; userspace uses
either), fastrpc-*, panel-display-off, imx582-1080p, dw9800-soft (his 0033,
0034, 0023, 0014, 0015).

Config: config.aarch64 (7.1) plus ../pro1x-7.3.fragment, through 7.3's
olddefconfig.  Checked locally (x86 host compiler): every option of
pro1x.fragment and pro1x-7.3.fragment survives; lost from the 7.1 config,
besides compiler-capability flags (an artefact of the host compiler):
CRYPTO_DEV_QCE*, CRYPTO_DEV_QCOM_RNG (dependencies changed in 7.3; not
needed to boot), PROC_SYSCTL (to check: renamed or merged in 7.3).

On branch kernel-7.3-trial (2026-11-02): with next and main merged and
0035 out; all 54 patches apply to v7.3 (checked).

State of kernel-7.3: built in CI (run 41388196979, 2026-11-02: kernel, U-Boot and the
mobile image; output /gnu/store/i5n6m4fc...-linux-pro1x-7.3.0); not yet
booted.
