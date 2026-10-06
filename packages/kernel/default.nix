{ lib, linuxKernel, ... }:

let
  patchDir = ../../device/kernel/patches;

  # order matters: later patches edit the same device tree.
  patches = [
    "touch" 
    "egpio"
    "dsi" # exactly 60 Hz panel link (fixes touch ghost events)
    "audio" 
    "q6voice" 
    "camera" # CAMSS, S5K4H7 (front), IMX582 + DW9800 (rear)
    "keyboard" # AW9523B matrix keyboard driver + DT
    "leds" # torch, keyboard backlight, flash led controller
    "power" # battery level charger input limit and watchdog
    "haptics" # AW86224 vibration motor
    "bluetooth" # WCN3950
    "ipa" # modem data path
  ];

  configfile = ../../device/kernel/config.aarch64;

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
  version = "7.1.0";
  modDirVersion = "7.1.0";
  src = builtins.fetchGit {
    url = "https://github.com/sm6115-mainline/linux.git";
    ref = "qx1050-7.1";
    rev = "8cd9520d35a6c38db6567e97dd93b1f11f185dc6";
    shallow = true;
  };
  config = parseConfig (builtins.readFile configfile);

  features.efiBootStub = true;

  kernelPatches = map (n: { name = "pro1x-${n}"; patch = patchDir + "/pro1x-${n}.patch"; }) patches;
}
