{ config, lib, pkgs, ... }:

# Userspace plumbing for the SM6115 modem (QRTR services). Nothing here has been
# verified on a Pro1X. The kernel side (remoteproc MPSS, IPA, QRTR with its own name
# service, and the in-kernel protection domain mapper QCOM_PD_MAPPER) is enabled in
# packages/kernel, so there is no pd-mapper daemon (nixpkgs does not ship one either).
#
# tqftpserv serves firmware to the modem (including wlanmdsp.mbn for Wi-Fi). Its
# nixpkgs build patches the base path to a directory that does not hold our
# firmware, so postPatch is replaced to point at /run/current-system/firmware
# (where hardware.firmware ends up).
let
  cfg = config.pro1x.modem;
  verbose = lib.optionalString cfg.verbose " -v";
in
{
  options.pro1x.modem = {
    enable = lib.mkEnableOption "Qualcomm modem userspace services (tqftpserv, rmtfs, ModemManager)";
    verbose = lib.mkEnableOption "verbose logging for the modem services";
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      (final: prev: {
        tqftpserv = prev.tqftpserv.overrideAttrs (old: {
          # Replaces (does not extend) the nixpkgs postPatch, which already rewrote
          # the path this substitution looks for.
          postPatch = ''
            substituteInPlace translate.c \
              --replace-fail '"/lib/firmware/"' '"/run/current-system/firmware/"'
          '';
        });
      })
    ];

    networking.modemmanager.enable = true;
    environment.systemPackages = with pkgs; [ libqmi qrtr ];

    systemd.services = {
      tqftpserv = {
        description = "TFTP server over QRTR (firmware for the modem)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.tqftpserv}/bin/tqftpserv${verbose}";
          Restart = "always";
          RestartSec = 1;
        };
      };
      rmtfs = {
        description = "Qualcomm remote filesystem service (modemst1/2, fsg, fsc)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          # -P reads the raw EFS partitions from /dev/disk/by-partlabel.
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -r -P -s${verbose}";
          Restart = "always";
          RestartSec = 1;
        };
      };
    };
  };
}
