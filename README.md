# NixOS on the F(x)tec Pro1X (QX1050)

Mainline Linux 7.1 (plus a set of small device patches) and U-Boot for the
F(x)tec Pro1X (Snapdragon 662 / SM6115), packaged as a Nix flake. Use it as a
ready-made Phosh system, or import it into your own NixOS configuration and
build the phone from that.

> Nothing here is guaranteed. Flashing **erases userdata** and replaces the
> bootloader chain on slot A. Unlock the bootloader and back up first.

## Port status

```
Display (BOE AMOLED, 60 Hz)     Works
GPU (Adreno 610)                Works
Touchscreen                     Works
Hardware keyboard               Works   custom AW9523B driver, backlight, Fn layer via keyd
Keyboard slider switch          Works   (phoc is patched, it crashed on this switch)
Wi-Fi                           Works   firmware is served through the modem, see modem.nix
Bluetooth                       Works
USB gadget (serial + network)   Works   172.16.42.1, ssh, nix copy
Speaker                         Works
Earpiece                        Works
Headphones                      Works   headset jack detection untested
Microphones                     Works
Calls                           Works   UCM "Voice Call" verb + q6voice kernel driver
SMS                             Works
Mobile data                     Works
GPS                             Untested
Rear camera (IMX582)            Works   12 MP, autofocus; no 48 MP mode
Front camera (S5K4H7)           Works
Camera controls                 Partly  software ISP: contrast/gamma only, no exposure/ISO/WB
Torch / flash LED               Works
Vibration motor                 Works   AW86224, strength tunable
Battery level                   Works   ADC-based estimate, not a real fuel gauge
Charging                        Works   input current limit + watchdog handled by a small driver
Suspend                         Works   s2idle down to RPM vmin, modem wakes it (see Credits)
Sensors (accel, gyro, mag, ALS, proximity)
                                Partly  ADSP via hexagonrpcd, start by hand, see below
Full-disk encryption            Works   LUKS2 + unl0kr on-screen unlock keyboard
SD card, NFC, video codecs      Untested
```

## Layout

```
flake.nix               outputs: nixosModules, nixosConfigurations, packages, lib
overlay.nix             pro1x-kernel / -firmware / -uboot / -audio / -libcamera, patched phoc
device/                 distro-independent: kernel patches + config, UCM, keyd, udev, libcamera, sensor files
packages/               Nix packages (kernel, uboot, firmware, audio, cameractrl)
modules/                NixOS modules (hardware, audio, camera, keyboard, modem, sensors, usb-network, encryption)
hosts/                  minimal (console + ssh) and phosh
lib/                    boot image / flash script builders (mkArtifacts)
scripts/                deploy.sh, flash-encrypted.sh, kernel config generator
tools/                  on-device diagnostics and tuning helpers
```

## Quick start (use the included hosts)

You need an x86_64 or aarch64 machine with Nix (flakes enabled), `fastboot`
access to the phone, and an unlocked bootloader. On x86_64 add this to your
NixOS config so the aarch64 parts of the build can run under qemu:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

Put the phone in fastboot mode, then:

```sh
git add -A                      # flakes only see tracked files
nix build .#flash-phosh         # or .#flash-minimal
./result/bin/pro1x-flash        # erases dtbo + userdata, flashes U-Boot (boot_a), vbmeta, rootfs
```

Slot B is not used. Log in as `nixos` / `nixos` (change it) on the screen, or
over USB: `ssh nixos@172.16.42.1`.

## Use it as a flake input (your own config)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pro1x.url = "github:nyymi609/fxtec-pro1x-nixos";
    pro1x.inputs.nixpkgs.follows = "nixpkgs";   # use one nixpkgs everywhere
  };

  outputs = { self, nixpkgs, pro1x, ... }: {
    nixosConfigurations.my-pro1x = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        pro1x.nixosModules.default       # the hardware support (kernel, firmware, audio, ...)
        pro1x.nixosModules.cross-kernel  # optional: cross-compile the kernel on x86_64
        pro1x.nixosModules.host-minimal  # optional: nixos user, ssh, NetworkManager
        ./configuration.nix              # yours: desktop, packages, users
      ];
    };

    # Images for the first flash (run on the PC)
    packages.x86_64-linux = pro1x.lib.mkImages "x86_64-linux" self.nixosConfigurations.my-pro1x;
    #   .flash  .flash-uboot  .rootfs  .uboot-img
  };
}
```

What you get from the flake:

| Output | What it is |
|---|---|
| `nixosModules.default` | hardware, audio, camera, keyboard, modem, sensors, usb-network (and encryption) |
| `nixosModules.cross-kernel` | sets `pro1x.kernelPackage` to a kernel cross-compiled on x86_64 |
| `nixosModules.host-minimal` / `host-phosh` | ready-made hosts to import or copy from |
| `overlays.default` | `pro1x-kernel`, `pro1x-firmware`, `pro1x-uboot`, `pro1x-audio`, `pro1x-libcamera`, patched `phoc` |
| `lib.mkArtifacts system cfg` | `{ flashScript, rootfsImg, ubootImg, flashUbootScript }` for any config that imports the default module |
| `lib.mkImages system cfg` | the same, named `flash`, `rootfs`, `uboot-img`, `flash-uboot` |

Enable the parts you want in your configuration (see "Configuration" below):

```nix
{
  pro1x.audio.enable = true;
  pro1x.camera.enable = true;
  pro1x.modem.enable = true;      # also needed for Wi-Fi firmware
  pro1x.sensors.enable = true;
}
```

The module sets `nixpkgs.hostPlatform = "aarch64-linux"`, installs its overlay
and allows unfree (Qualcomm firmware) itself.

## Cross-compiling

Only the **kernel and U-Boot** are cross-compiled. They are the slow part and
are not in any binary cache. The rest of the system stays native aarch64, so it
is downloaded from cache.nixos.org (anything missing is built under qemu).
Cross-building everything would miss the cache and rebuild half of nixpkgs.

On an x86_64 PC:

1. `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` in the PC's NixOS config (rebuild once).
2. Import `pro1x.nixosModules.cross-kernel` in your phone configuration, or use the
   built-in `*-xc` configurations (`phosh-xc`, `minimal-xc`).
3. `mkArtifacts "x86_64-linux" cfg` builds U-Boot with the cross toolchain and
   uses the PC's own `fastboot`, `mkbootimg` and `e2fsprogs`, so USB talks natively
   instead of through qemu.

Just the kernel (fast check that your patches apply and build):

```sh
nix build .#kernel
```

On an aarch64 machine leave out `cross-kernel`; everything builds natively.
Note that a cross-built and a native kernel are different derivations, so
rebuilding on the phone without `cross-kernel` builds the kernel again (slowly).
Build on the PC and deploy, or point the phone at the PC as a remote builder.

## Build your own image from your own config

A small flake that imports the default module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pro1x.url = "github:nyymi609/fxtec-pro1x-nixos";
    pro1x.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, pro1x, ... }: rec {
    nixosConfigurations.my-pro1x = nixpkgs.lib.nixosSystem {
      modules = [
        pro1x.nixosModules.default
        pro1x.nixosModules.cross-kernel   # on an x86_64 PC, see "Cross-compiling"
        ./configuration.nix
      ];
    };
    packages.x86_64-linux = pro1x.lib.mkImages "x86_64-linux" nixosConfigurations.my-pro1x;
  };
}
```

```sh
git init && git add -A
nix build .#flash
./result/bin/pro1x-flash                # phone in fastboot mode
```

`configuration.nix` is a normal NixOS module. Anything NixOS supports works as
long as it runs on aarch64 with a Wayland or console stack. Keep these in it:

- a user with a password or ssh key (`host-minimal` defines `nixos`/`nixos`, change it),
- `pro1x.audio.enable`, `pro1x.modem.enable`, ... for the hardware you use.

The rootfs is a plain ext4 image written to `userdata`; the first boot registers
the closure in the Nix store and the root filesystem grows to fill the partition.

### Encrypted root

```nix
pro1x.encryption.enable = true;
```

Root becomes a LUKS2 container. The initrd shows the on-screen
keyboard (unl0kr) at every boot; the hardware keyboard works too. The first
`bootSize` MiB (default 1024) of `userdata` stay a plain ext4 `/boot`, because
U-Boot must read the kernel before anything can be decrypted. It cannot be
enabled on an existing install; reflash with the same `pro1x-flash` (it asks for
the passphrase and builds the image without root). Change the passphrase on the
phone with `sudo cryptsetup luksChangeKey /dev/loop0`. For a broken initrd set
`pro1x.encryption.debugShell = true` (serial console, then turn it off again).

### Updating without reflashing

```sh
git add -A
./scripts/deploy.sh my-pro1x-xc            # nixosConfigurations name, optional phone address
# from your own flake:  nix run github:nyymi609/fxtec-pro1x-nixos#deploy -- my-pro1x
```

This builds on the PC, `nix copy`s the system to the phone, sets the profile and
writes the U-Boot entry. Reboot to use it. The previous generations stay selectable from
the U-Boot menu (hold volume-down at boot, then "Boot previous generation N"), so a bad
update is recoverable. To reflash only the
bootloader (first install, recovery): `nix build .#flash-uboot && ./result/bin/pro1x-flash-uboot`.

## Configuration

Options of this flake's modules:

| Option | Default | |
|---|---|---|
| `pro1x.kernelPackage` | `pkgs.pro1x-kernel` | use your own kernel derivation |
| `pro1x.serial.enable` | off | USB serial console `ttyGS0` |
| `pro1x.verbose` | off | earlycon on the debug UART, debug logging |
| `pro1x.usbNetwork.enable` / `.address` | on / `172.16.42.1/24` | Ethernet over the USB gadget with a DHCP server |
| `pro1x.audio.enable` | off | PipeWire, UCM profile, voice call session |
| `pro1x.camera.enable` | off | patched libcamera (software ISP), Snapshot, `cameractr` |
| `pro1x.modem.enable` / `.verbose` | off | tqftpserv, rmtfs, ModemManager |
| `pro1x.keyboard.enable` | on | Finnish `nodeadkeys` layout and keyd Fn layer |
| `pro1x.sensors.enable` | off | ADSP sensors through hexagonrpcd + iio-sensor-proxy |
| `pro1x.sensors.autostart` | off | start the sensor daemon at boot (it can hang the phone, try by hand first: `systemctl start pro1x-hexagonrpcd`) |
| `pro1x.sensors.accelMountMatrix` | identity | fix auto-rotate direction, e.g. `"0, -1, 0; 1, 0, 0; 0, 0, 1"` |
| `pro1x.consoleRotation` | null | rotate the text console / TTY login: `1` or `2` for landscape with the keyboard out. |
| `pro1x.bootMenu.generations` | 3 | previous generations listed in the U-Boot menu (0-9, 0 = none). Built into U-Boot: reflash it after changing (`nix build .#flash-uboot`). Keep it below `configurationLimit` |
| `pro1x.encryption.enable` / `.bootSize` / `.allowDiscards` / `.debugShell` | off / 1024 / on / off | see above |
| `pro1x.display.bottomGap` | 0 | lines at the bottom of the panel left unused (0-400), workaround for as this display gets black dots on the edges overtime. Can be used for removing the rounded corners together with topGap. |
| `pro1x.display.topGap` | 0 | lines at the top of the panel left unused (0-400). |

## Customizing

The drivers that are specific to this phone expose their knobs as **module
parameters**. They can be changed live under `/sys/module/<driver>/parameters/`
(as root, effective immediately or from the next event), and made permanent in
NixOS with either of:

```nix
boot.kernelParams = [ "aw86224.drv2_lvl=80" ];                    # driver.param=value
boot.extraModprobeConfig = "options aw86224 drv2_lvl=80";        # same thing
```

### Vibration motor (AW86224)

Driver `aw86224`. The motor is driven by feedbackd (the udev rule gives group
`feedbackd` access; users need that group) or directly through the force-feedback
input device `aw86224-haptics`.

| Parameter | Meaning | Default |
|---|---|---|
| `drv2_lvl` | sustained drive level at full strength, 0-127 (stock 59). The part you feel in a long buzz | 59 |
| `drv1_lvl` | start-up drive level, 0-127 | 127 |
| `d2s_gain` | output gain code 0-7 = x1, x2, x4, x5, x8, x10, x20, x40 (stock 5) | 6 |

Stronger settings warm the motor, so use them in short bursts. Try values with:

```sh
sudo bash tools/haptics-tune.sh              # sweep from stock to strongest, one buzz each
sudo bash tools/haptics-tune.sh 7 100        # one buzz with gain 7, drive 100
bash tools/haptics-check.sh                  # permissions, udev, feedbackd end to end
```

then keep the winner: `boot.kernelParams = [ "aw86224.d2s_gain=7" "aw86224.drv2_lvl=100" ];`.

### Charging and battery

| Driver / parameter | Meaning | Default |
|---|---|---|
| `pro1x_charger_icl.max_icl_ma` | highest USB input current limit to set, mA (0 = do nothing) | 1500 |
| `pro1x_charger_icl.min_icl_ma` | raise the limit to at least this on any source, even plain USB detection. The charger still backs off if the source sags. Never above `max_icl_ma` | 0 (off) |
| `pro1x_charger_icl.pet_wdog` | feed the charger watchdog while USB is present (without it charging stops after a few minutes) | on |
| `pro1x_adc_battery.esr_mohm` | battery internal resistance used for load compensation | 150 |
| `pro1x_adc_battery.esr_learn` | learn the resistance while running (`0` keeps your value) | on |
| `pro1x_adc_battery.debug` | log every poll | off |

Example, 2 A charging with a good charger and cable:

```nix
boot.kernelParams = [ "pro1x_charger_icl.max_icl_ma=2000" ];
```

The "battery full" voltage defaults to 4.38 V and can be set with the device tree
property `fxtec,full-voltage-microvolt` on the gauge node (see
`device/kernel/patches/pro1x-power.patch`). `sudo bash tools/charger-status.sh`
(plugged in) dumps the charger registers and logs a few minutes of state.

### Keyboard

- Layout: `pro1x.keyboard.enable` sets Finnish `nodeadkeys`. To use another layout:
  `services.xserver.xkb.layout = lib.mkForce "us";` (and `variant`).
- Fn layer: `device/input/keyd.conf`, installed to `/etc/keyd/default.conf`. Replace it with
  `environment.etc."keyd/default.conf".source = lib.mkForce ./my-keyd.conf;`.
  `keyd monitor` shows what each key sends.
- Matrix scan timing (module `pro1x_aw9523_kbd`, built in, so use the kernel command line):
  `settle_us` (delay between column and row read, default 20), `stock_scan` (scan like the
  stock driver), `debug_keys` (log raw scans). Example: `"pro1x_aw9523_kbd.settle_us=40"`.
- Backlight: an LED named `white:kbd_backlight`, see `brightnessctl -l`.

### Torch and flash LED

The PMI632 flash controller shows up as LEDs under `/sys/class/leds` (white and
amber, `brightnessctl -l` lists them). Write a brightness to turn the torch on:
`brightnessctl -d <name> set 1`. The current limit per channel
(`led-max-microamp`, 100 mA) is in `device/kernel/patches/pro1x-leds.patch`.

### Audio

- Card description: `device/audio/ucm2/Pro1X/` (`HiFi.conf` for Speaker, Headphones, Earpiece, mics;
  `VoiceCall.conf` for calls). Edit, rebuild, restart WirePlumber.
- Mixer defaults applied before WirePlumber starts: `device/audio/pro1x-audio-init`.
- Calls: `pro1x-voice-call` and `pro1x-voicepcm` (user service started by the Voice Call verb).
- Volume safety: there are no safe default volumes yet; lower them before putting on headphones.

### Camera

`pro1x.camera.enable` points WirePlumber at a libcamera patched with the two sensors
(`device/libcamera/`). Tuning is limited to what libcamera's software ISP offers (contrast, gamma).
Rear lens focus: `tools/cam-focus.sh 0..1023` (about 100 = 1 m, higher = closer) while a
camera app is open on the rear camera.

### Sensors

Accelerometer, gyroscope, magnetometer, light and proximity belong to the ADSP, not to Linux.
`hexagonrpcd` serves the configuration files in `device/hexagonfs` (copied from this unit's
own Android install; regenerate with `sudo bash tools/sensors-collect.sh` and point
`pro1x.sensors.hexagonfs` at your copy). Check everything with
`sudo bash tools/sensors-check.sh`, and flip `accelMountMatrix` if the screen rotates the wrong way.

### Kernel

- Patches: `device/kernel/patches/pro1x-*.patch`, applied in the order listed in
  `packages/kernel/default.nix` (later ones edit the same device tree).
- To add one: drop `pro1x-foo.patch` into that directory and add `"foo"` to the list.
- Config: `device/kernel/pro1x.fragment` is applied on top of arm64 defconfig. The full
  `config.aarch64` is generated by the kernel's own Kconfig (nixpkgs' generator cannot
  handle options that depend on later ones). After editing the fragment or changing patches
  that add Kconfig options:

  ```sh
  git clone --depth 1 -b qx1050-7.1 https://github.com/sm6115-mainline/linux.git /tmp/linux
  ./scripts/gen-kernel-config.sh /tmp/linux      # fails if an option does not stick
  ```
- Source: `github.com/sm6115-mainline/linux`, branch `qx1050-7.1`, pinned by commit in
  `packages/kernel/default.nix`.
- A completely different kernel: build your own derivation and set `pro1x.kernelPackage`.
- Extra command line arguments: `boot.kernelParams`. With `pro1x.verbose = true` you get
  earlycon on the debug UART (`0x4a90000`).

### Debugging

```nix
pro1x.serial.enable = true;   # USB serial console on the PC: screen /dev/ttyACM0 115200
pro1x.verbose = true;         # debug UART + verbose logging
```

Hold volume-down during boot for the U-Boot menu (previous generations).

## Other distros

`device/` is distro-independent. Apply the kernel patches and config, install
`device/audio/ucm2` into alsa-ucm-conf, run `pro1x-audio-init` at boot, and use
`device/input/keyd.conf` and `device/udev/60-pro1x.rules`.

## Development
AI coding tools were used to develop this port.

## Tools

`tools/charger-status.sh`, `haptics-check.sh`, `haptics-tune.sh`, `cam-focus.sh`,
`sensors-check.sh`, `sensors-collect.sh`, `fde-check.sh`, `qg-probe.sh`.
They are read-only unless the header says otherwise; most need `sudo` on the phone.

## Credits

Kernel base and firmware from the sm6115-mainline project, boot image and build
knowledge from macneisj's Pro1X build script and the postmarketOS port.

The sleep, display, audio, charger and battery fixes in `device/kernel/patches/` come from
moWerk's SailfishOS port of this phone,
[sailfishos-pro1x-mainline](https://github.com/moWerk/sailfishos-pro1x-mainline)
(`kernel/patches-7.3`, itself based on this repository), brought back to 7.1 and folded into
the patches here. Its `kernel/HANDOVER.md` explains each one. Some of them came from the
[Lenovo TB-J606L port](https://github.com/haltia-de/device-lenovo-tb-j606l).
The modem wake (`pro1x-qrtr-modem-wake`, in `pro1x-sleep.patch`) comes from the
[Guix port](https://github.com/mlaparie/fxtec-pro1x-guix).
