final: prev: {
  pro1x-kernel = final.callPackage ./packages/kernel { };
  pro1x-firmware = final.callPackage ./packages/firmware { };
  pro1x-uboot = final.callPackage ./packages/uboot { };
  pro1x-audio = final.callPackage ./packages/audio { };
  pro1x-cameractrl = final.callPackage ./packages/cameractrl { };

  # libcamera with the Pro1X sensors (S5K4H7 front, IMX582 rear): sensor helpers
  # with the analogue gain model and black level. Kept under its own name so nothing
  # else rebuilds.
  pro1x-libcamera = prev.libcamera.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./device/libcamera/s5k4h7-sensor.patch
      ./device/libcamera/imx582-sensor.patch
    ];
  });

  # phoc aborts on any switch that is neither lid nor tablet-mode, e.g. the keyboard
  # slide sensor (SW_KEYPAD_SLIDE), so Phosh crash-loops while the keyboard is open.
  # Ignore such switches instead.
  phoc = prev.phoc.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./device/phoc/ignore-unknown-switch.patch ];
  });
}
