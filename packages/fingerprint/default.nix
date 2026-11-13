{ lib, stdenv, stdenvNoCC, fetchFromGitHub, fetchurl }:

# The fingerprint reader (modules/fingerprint.nix). The sensor sits on an SPI
# bus that TrustZone owns; only the stock trusted app, mafp, can read it. The
# kernel's QSEECOM TEE driver (patch pro1x-qseecom-tee) loads and drives it.
# Ported from fxtec-pro1x-guix (github.com/mlaparie/fxtec-pro1x-guix), whose
# device/fingerprint/README.md maps the whole stack.
{
  # Answers the TA's file system listener requests (its templates, under
  # /var/lib/qsee-supplicant); qsee-app-loader keeps one named app loaded.
  qsee-supplicant = stdenv.mkDerivation {
    pname = "qsee-supplicant";
    version = "0.1.1-unstable-36e0668";
    src = fetchFromGitHub {
      owner = "wrobelda";
      repo = "qsee-supplicant";
      rev = "36e06680cf7f690fccbdcd07abc2a64c4bb061d8";
      hash = "sha256-UGnO3io7uC22a1hDXpVwliWchkErDRLPcjXV3Xqv868=";
    };
    makeFlags = [ "CC=${stdenv.cc.targetPrefix}cc" "PREFIX=$(out)" ];
    # The programs only: the units are written in the module
    installTargets = [ "install-bin" "install-doc" ];
    meta = {
      description = "Listener services and app loader for Qualcomm QSEE";
      homepage = "https://github.com/wrobelda/qsee-supplicant";
      license = lib.licenses.bsd2;
      platforms = lib.platforms.linux;
    };
  };

  # The trusted app as one signed image (the driver loads <name>.mbn when
  # there is no <name>.mdt), from the LineageOS vendor blobs.
  mafp-firmware = stdenvNoCC.mkDerivation {
    pname = "fxtec-qx1050-mafp";
    version = "lineage-21-ea4f9ed";
    src = fetchurl {
      url = "https://raw.githubusercontent.com/TheMuppets/proprietary_vendor_fxtec_pro1x/ea4f9ed909f932b3b5f1322bf8605c222313a444/proprietary/vendor/firmware/mafp.mbn";
      hash = "sha256-lZfHzvyYziPYayWC5EiypZHO1WH/Sf2hwcGmuMhGcK4=";
    };
    dontUnpack = true;
    dontFixup = true; # an ELF, but not for Linux
    installPhase = "install -Dm644 $src $out/lib/firmware/mafp.mbn";
    meta = {
      description = "Fingerprint trusted app of the F(x)tec Pro1X (MicroArray, QSEE)";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  # The daemon over mafp, and its client (the same program): enrol, list,
  # remove, identify on /run/pro1x-fpd.sock. moWerk's sailfish-fpd-mafp
  # protocol in C, by fxtec-pro1x-guix.
  pro1x-fpd = stdenv.mkDerivation {
    pname = "pro1x-fpd";
    version = "0.1";
    src = ../../device/fingerprint/pro1x-fpd;
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -o pro1x-fpd pro1x-fpd.c
      runHook postBuild
    '';
    installPhase = "install -Dm755 pro1x-fpd $out/bin/pro1x-fpd";
    meta = {
      description = "Fingerprint daemon for the F(x)tec Pro1X";
      homepage = "https://github.com/mlaparie/fxtec-pro1x-guix";
      license = lib.licenses.gpl3Plus;
      platforms = lib.platforms.linux;
      mainProgram = "pro1x-fpd";
    };
  };
}
