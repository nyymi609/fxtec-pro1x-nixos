{ config, lib, pkgs, ... }:

# The Pro1X itself: kernel, device tree, firmware, initrd, U-Boot boot entries,
# consoles, root filesystem, udev rules. Everything every host needs.
let
  cfg = config.pro1x;
in
{
  options.pro1x = {
    kernelPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pro1x-kernel;
      defaultText = lib.literalExpression "pkgs.pro1x-kernel";
      description = ''
        Kernel to use. The flake sets this to a kernel cross-compiled on an x86_64
        build host (fast) while the rest of the system stays native aarch64
        (substituted from cache.nixos.org, or built under binfmt).
      '';
    };

    serial.enable = lib.mkEnableOption "USB serial gadget console (ttyGS0) for debugging";

    verbose = lib.mkEnableOption "verbose kernel/systemd logging and earlycon on the debug UART";
  };

  config = {
    nixpkgs = {
      hostPlatform = "aarch64-linux";
      overlays = [ (import ../overlay.nix) ];
      config.allowUnfree = true; # Qualcomm firmware
    };

    boot.kernelPackages = pkgs.linuxPackagesFor cfg.kernelPackage;

    hardware = {
      deviceTree = {
        enable = true;
        name = "qcom/sm6115-fxtec-pro1x.dtb";
      };
      # Device firmware lives under qcom/sm6115/Fxtec/QX1050/ (matches the DTS).
      firmware = [ pkgs.pro1x-firmware ];
      enableRedistributableFirmware = true; # linux-firmware: a610 SQE, ath10k, qca BT
      # Qualcomm remoteproc loaders want uncompressed images.
      firmwareCompression = "none";
    };

    boot.initrd = {
      # Everything needed to reach UFS is built in (see device/kernel/pro1x.fragment).
      includeDefaultModules = false;
      compressor = "zstd";
      systemd = {
        enable = true;
        tpm2.enable = false;
      };
    };

    # Boot: stock ABL -> U-Boot (boot_a) -> /boot/extlinux/extlinux.conf on the ext4
    # rootfs. Every `nixos-rebuild`/deploy adds a U-Boot menu entry; old generations
    # stay selectable (hold volume-down at boot).
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible = {
      enable = true;
      configurationLimit = 5;
    };
    boot.loader.timeout = lib.mkDefault 3;

    boot.kernelParams = [
      "loglevel=4"
      # Serial console on the debug UART (GENI @ 0x4a90000), then the panel.
      # Last console listed becomes /dev/console.
      "console=ttyMSM0,115200n8"
    ]
    ++ lib.optionals cfg.serial.enable [
      "console=ttyGS0,115200"
      "systemd.log_target=console"
    ]
    ++ lib.optionals cfg.verbose [
      "earlycon=msm_geni_serial,0x4a90000"
      "ignore_loglevel"
      "systemd.log_level=debug"
    ]
    ++ [ "console=tty1" ];

    # The Pro1X userdata partition has 4096-byte sectors.
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    # Register the initial closure on first boot (image is built offline).
    boot.postBootCommands = ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
        rm -f /nix-path-registration
      fi
    '';

    console.earlySetup = true;

    systemd.services."serial-getty@ttyGS0" = lib.mkIf cfg.serial.enable {
      enable = true;
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Restart = "always";
    };

    # dma-buf providers for the camera, haptics device for feedbackd.
    services.udev.extraRules = builtins.readFile ../device/udev/60-pro1x.rules;
    users.groups.feedbackd = { };

    system.stateVersion = lib.mkDefault "26.05";
  };
}
