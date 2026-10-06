{ buildUBoot, xxd }:
(buildUBoot {
  version = "2026.10-rc-f8eb346";

  src = builtins.fetchGit {
    url = "https://github.com/u-boot/u-boot.git";
    rev = "f8eb3469e1a17c79b047b3fd38ae820e8816a115";
  };

  defconfig = "qcom_defconfig qcom-phone.config";
  extraMakeFlags = [ "DEVICE_TREE=qcom/sm6115-fxtec-pro1x" ];
  extraMeta.platforms = [ "aarch64-linux" ];

  extraConfig = ''
    CONFIG_CMD_HASH=y
    CONFIG_CMD_UFETCH=y
    CONFIG_CMD_SYSBOOT=y
  '';

  prePatch = ''
    substituteInPlace board/qualcomm/qcom-phone.env \
      --replace-fail 'bootcmd=bootefi bootmgr; pause; run menucmd' \
      'bootcmd=sysboot scsi 0#userdata any ''${scriptaddr} /boot/extlinux/extlinux.conf; pause; run menucmd'
    substituteInPlace board/qualcomm/qcom-phone.env \
      --replace-fail 'bootmenu_0=Boot=bootefi bootmgr; pause' \
      'bootmenu_0=Boot=sysboot scsi 0#userdata any ''${scriptaddr} /boot/extlinux/extlinux.conf; pause'

    # Bring-up fixes found on the Pro1X: USB gadget needs high-speed peripheral
    # mode + UTMI pipe clock (no SS PHY driver); UFS needs its GDSC.
    cat >> dts/upstream/src/arm64/qcom/sm6115-fxtec-pro1x.dts <<'EOF'

    &usb_dwc3 {
    	/delete-property/ usb-role-switch;
    	maximum-speed = "high-speed";
    	dr_mode = "peripheral";

    	phys = <&usb_hsphy>;
    	phy-names = "usb2-phy";
    };

    &usb {
    	qcom,select-utmi-as-pipe-clk;
    };
    EOF
    substituteInPlace drivers/clk/qcom/clock-sm6115.c \
      --replace-fail '	[GCC_USB30_PRIM_GDSC] = { 0x1a004 },' \
      '	[GCC_UFS_PHY_GDSC] = { 0x45004 },
    	[GCC_USB30_PRIM_GDSC] = { 0x1a004 },'
  '';

  filesToInstall = [
    "u-boot*"
    "dts/upstream/src/arm64/qcom/sm6115-fxtec-pro1x.dtb"
  ];
}).overrideAttrs (old: {
  # qcom-phone.env is converted to a C array with xxd.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ xxd ];
})
