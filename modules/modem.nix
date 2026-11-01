{ config, lib, pkgs, ... }:

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
          postPatch = ''
            substituteInPlace translate.c \
              --replace-fail '"/lib/firmware/"' '"/run/current-system/firmware/"'
          '';
        });
      })
    ];

    networking.modemmanager.enable = true;
    # mm-netlink calls a transaction's completion function after freeing it:
    # ModemManager segfaults (netlink_messages_cb) when it sets up qmapmux0.0,
    # often after a resume, and mobile data is gone until it is back. Only the
    # daemon is patched, so what links libmm-glib isn't rebuilt.
    networking.modemmanager.package = pkgs.modemmanager.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ../packages/modemmanager/netlink-use-after-free.patch ];
    });
    environment.systemPackages = with pkgs; [ libqmi qrtr ];

    systemd.services = {
      ModemManager = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "rmtfs.service" "tqftpserv.service" ];
        after = [ "rmtfs.service" "tqftpserv.service" ];
      };

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
          ExecStartPre = pkgs.writeShellScript "rmtfs-wait-modem" ''
            export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
            i=0
            while [ "$i" -lt 180 ]; do
              for n in /sys/class/remoteproc/*/name; do
                [ -r "$n" ] && [ "$(cat "$n")" = modem ] && exit 0
              done
              i=$((i + 1))
              sleep 1
            done
            echo "modem remoteproc did not appear" >&2
            exit 1
          '';
          TimeoutStartSec = 240;
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -r -P -s${verbose}";
          Restart = "always";
          RestartSec = 1;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };

      # The GNSS engine comes up locked (NV 452 gps1_lock = 3, MI and MT):
      # Android's location HAL unlocks it, here nothing did and every session
      # stayed silent. rmtfs -r keeps the modem's NV writes in RAM, so it is
      # unlocked again at every boot. ModemManager's GPS reads NMEA, and its
      # own "setup NMEA traces" times out on this modem (the Get NMEA Types
      # indication comes before the response), so the types are set here too.
      pro1x-gnss-unlock = {
        description = "Unlock the modem's GNSS engine";
        wantedBy = [ "multi-user.target" ];
        after = [ "rmtfs.service" "ModemManager.service" ];
        wants = [ "rmtfs.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 300;
        };
        path = [ pkgs.libqmi pkgs.qrtr pkgs.gnugrep pkgs.coreutils ];
        script = ''
          # The modem's location service (16) shows up a while after boot
          for _ in $(seq 120); do
            qrtr-lookup | grep -q '^ *16 .* 0 ' && break
            sleep 2
          done
          for _ in $(seq 5); do
            qmicli -d qrtr://0 --loc-set-engine-lock=none &&
              qmicli -d qrtr://0 --loc-set-nmea-types='gga|rmc|gsv|gsa|vtg' &&
              exit 0
            sleep 5
          done
          exit 1
        '';
      };
    };
  };
}
