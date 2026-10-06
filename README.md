# F(x)tec Pro1X - mainline Linux (NixOS)

Mainline Linux 7.1 (+12 small patches) and U-Boot for the F(x)tec Pro1X (QX1050 / SM6115).

## Status

| Works | Partly / untested | Missing |
|---|---|---|
| Display, touch, keyboard (+backlight) | Fn-layer keys, headset jack detect | IMX582 48 MP mode |
| Wi-Fi, Bluetooth, USB gadget network | Voice calls (UCM `VoiceCall` verb) | libcamera tuning files |
| Speaker, earpiece, headphones, mics | Haptics, flash LED | |
| Rear/front camera (S5K4H7, IMX582 12 MP), autofocus | | |
| Battery gauge, charging (watchdog + ICL) | | |
| Modem (IPA / Q6 voice), GPU, suspend | | |

## Install (PC with Nix, flakes enabled; phone bootloader unlocked, fastboot mode)

```sh
git add -A
nix build .#flash-phosh      # or or flash-minimal
./result/bin/pro1x-flash     # erases dtbo, flashes U-Boot (boot_a), vbmeta, userdata; activates slot a
```
Slot b does not boot. On x86_64 add nothing: `<host>-xc` configurations use the cross-compiled kernel (the `flash-*` packages pick it on x86_64).
Reflash only U-Boot: `nix build .#flash-uboot && ./result/bin/pro1x-flash-uboot`.

Login: user `nixos`, password `nixos` (change it; add your ssh key in `hosts/minimal`). Phone is `172.16.42.1` over USB.

## Update

```sh
git add -A && ./scripts/deploy.sh phosh-xc   # any nixosConfigurations name, optional phone address
```
Reboot; older generations stay in the U-Boot menu (hold volume-down).

## Add the module to your own config

```nix
nixosConfigurations.my-pro1x = nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [
    pro1x.nixosModules.default       # hardware support
    pro1x.nixosModules.cross-kernel  # optional: cross-compile the kernel on x86_64
    pro1x.nixosModules.host-minimal  # optional: user, ssh, NetworkManager
    ./configuration.nix
  ];
};
```

## Kernel

Patches: `device/kernel/patches/`, config: `device/kernel/pro1x.fragment`.
Regenerate `config.aarch64` with `scripts/gen-kernel-config.sh`. Source: github.com/sm6115-mainline, branch `qx1050-7.1`, pinned in `packages/kernel`.

