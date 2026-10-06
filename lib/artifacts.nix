{ hostPkgs, uboot, lib, nixosConfig }:

let
  cfg = nixosConfig.config;
  toplevel = cfg.system.build.toplevel;
  params = import ./bootimg.nix;

  # AVB image with verification disabled; ABL refuses unsigned images otherwise.
  vbmetaImg = hostPkgs.runCommand "vbmeta.img" { nativeBuildInputs = [ hostPkgs.python3 ]; } ''
    python3 ${../scripts/mkvbmeta.py} $out
  '';

  # U-Boot wrapped as the Android "kernel" that the stock ABL loads.
  ubootImg = hostPkgs.runCommand "uboot.img"
    { nativeBuildInputs = [ hostPkgs.android-tools hostPkgs.gzip ]; } ''
    # U-Boot's arm64 Image header has text_offset = -0x80000000; the stock ABL
    # rejects that (straight back to fastboot). Linux has 0 there.
    cp ${uboot}/u-boot-nodtb.bin u-boot.bin
    chmod u+w u-boot.bin
    dd if=/dev/zero of=u-boot.bin bs=1 seek=8 count=8 conv=notrunc
    gzip --no-name -9 -c u-boot.bin > u-boot.bin.gz
    cat u-boot.bin.gz ${uboot}/sm6115-fxtec-pro1x.dtb > u-boot.bin.gz-dtb
    mkbootimg \
      --kernel u-boot.bin.gz-dtb \
      ${params.mkbootimgFlags params} \
      --output $out
  '';

  rootfsImg = hostPkgs.callPackage "${hostPkgs.path}/nixos/lib/make-ext4-fs.nix" {
    storePaths = [ toplevel ];
    volumeLabel = "nixos";
    compressImage = false;
    populateImageCommands = ''
      mkdir -p ./files/boot
      ${cfg.boot.loader.generic-extlinux-compatible.populateCmd} -c ${toplevel} -d ./files/boot
    '';
  };

  confirm = ''
    echo "This ERASES userdata on the connected F(x)tec Pro1X (fastboot mode)."
    read -r -p "Type 'flash' to continue: " a; [ "$a" = flash ] || exit 1
  '';

  # First install: U-Boot into boot_a (slot b does not boot on this phone), vbmeta, rootfs.
  flashScript = hostPkgs.writeShellApplication {
    name = "pro1x-flash";
    runtimeInputs = [ hostPkgs.android-tools ];
    text = confirm + ''
      fastboot erase dtbo
      fastboot flash boot_a ${ubootImg}
      fastboot flash vbmeta_a ${vbmetaImg}
      fastboot flash userdata ${rootfsImg}
      fastboot set_active a
      fastboot reboot
    '';
  };

  # Only U-Boot + vbmeta, userdata untouched (new U-Boot build, or recovery).
  flashUbootScript = hostPkgs.writeShellApplication {
    name = "pro1x-flash-uboot";
    runtimeInputs = [ hostPkgs.android-tools ];
    text = ''
      fastboot flash boot_a ${ubootImg}
      fastboot flash vbmeta_a ${vbmetaImg}
      fastboot set_active a
      fastboot reboot
    '';
  };
in
{
  inherit vbmetaImg ubootImg rootfsImg flashScript flashUbootScript;
}
