{ lib, linuxKernel, fetchurl, runCommand, ... }:

# Mainline 7.3 with moWerk's Pro1-X series (device/kernel/patches-7.3, from
# his SailfishOS port by way of fxtec-pro1x-guix; README.md there says what is
# left out), then ours. 7.1 (the sm6115-mainline tree with this repo's own
# series) never reached RPM vlow/vmin in suspend; the 7.3 series does.
let
  seriesDir = ../../device/kernel/patches-7.3;
  patchDir = ../../device/kernel/patches;

  # His series, in file-name order
  series = lib.sort lib.lessThan
    (lib.filter (lib.hasSuffix ".patch") (lib.attrNames (builtins.readDir seriesDir)));

  # Ours on top; order matters where they edit the same device tree.
  patches = [
    "panelgap" # top_gap/bottom_gap: shorter panel mode, for dead rows / rounded corners
    "dpugap" # msm.display_top_gap/bottom_gap: full link timing, picture moved down, black gaps
    "qrtr-modem-wake" # only the QMI services in qrtr.wake_ports wake the system (wm-suspend)
    "charger-awake-switch" # his "awake while charging" as a module parameter
    # Fingerprint reader (modules/fingerprint.nix), from fxtec-pro1x-guix:
    "qseecom-tee" # Dawid Wróbel's QSEECOM TEE driver: loads and drives QSEE trusted apps
    # moWerk's fixes for it: without the first two a store of several
    # templates hangs the phone; without the last the TA's replies are lost
    "tzmem-bridge-errno"
    "qseecom-listener-rounds"
    "qseecom-inout"
    "fingerprint-key" # the sensor's interrupt as a wake key (KEY_WAKEUP)
  ];

  # The 7.1 config plus what the 7.3 series needs, settled by the build's
  # oldconfig
  configfile = runCommand "pro1x-7.3.config" { } ''
    cat ${../../device/kernel/config.aarch64} ${../../device/kernel/pro1x-7.3.fragment} > $out
  '';

  # y/m summary of the config, in the format nixpkgs/NixOS inspects, without building the config first.
  parseConfig = content:
    let
      parseLine = line:
        let m = builtins.match "(CONFIG_[A-Za-z0-9_]+)=([ym])" line;
        in lib.optional (m != null) { name = builtins.elemAt m 0; value = builtins.elemAt m 1; };
    in
    builtins.listToAttrs (lib.concatMap parseLine (lib.splitString "\n" content));
in
linuxKernel.manualConfig {
  inherit lib configfile;
  version = "7.3.0";
  modDirVersion = "7.3.0";
  src = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.tar.xz";
    hash = "sha256-hzY8JPEOBjIes2J2VSEJTpRHH2v/i84taz5A858ASVM=";
  };
  config = parseConfig (builtins.readFile ../../device/kernel/config.aarch64
    + builtins.readFile ../../device/kernel/pro1x-7.3.fragment);

  features.efiBootStub = true;

  kernelPatches =
    map (f: { name = lib.removeSuffix ".patch" f; patch = seriesDir + "/${f}"; }) series
    ++ map (n: { name = "pro1x-${n}"; patch = patchDir + "/pro1x-${n}.patch"; }) patches;
}
