{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.diag;
  diagPkg = pkgs.pro1x-diag.override { debug = cfg.debug; };
in
{
  options.pro1x.diag = {
    enable = lib.mkEnableOption
      "Qualcomm DIAG router (modem diagnostics over rpmsg, for RF/signalling debugging). Untested";
    debug = lib.mkEnableOption
      "debug prints in diag-router (log masks sent to the modem, QRTR data packets); read them with journalctl -u diag-router";
    bootCapture = lib.mkEnableOption ''
      recording the modem's debug messages (RF, LTE RRC, MAC RACH) from its
      RF start at every boot, for 3 minutes, into /var/lib/diag/boot-*.bin.
      Started before rmtfs, so the RF device creation (PA, switches,
      PAPM/QPOET) is in it. Tools then use 127.0.0.1:2501 once it is done'';
  };

  config = lib.mkIf cfg.enable {
    # CONFIG_RPMSG_CHAR / CONFIG_RPMSG_CTRL are built as modules in the Pro1X kernel.
    boot.kernelModules = [ "rpmsg_char" "rpmsg_ctrl" ];
    environment.systemPackages = [ diagPkg ];

    systemd.services = {
      # QCSuper reads the PTY /run/diag; the router connects to the TCP socket.
      diag-bridge = {
        description = "PTY bridge for diag-router (QCSuper reads /run/diag)";
        wantedBy = [ "multi-user.target" ];
        before = [ "diag-router.service" "rmtfs.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:2500,bind=127.0.0.1,reuseaddr PTY,link=/run/diag,raw,echo=0,ignoreeof";
          Restart = "always";
        };
      };

      diag-router = {
        description = "Qualcomm DIAG router";
        wantedBy = [ "multi-user.target" ];
        after = [ "diag-bridge.service" ];
        requires = [ "diag-bridge.service" ];
        before = [ "rmtfs.service" ];
        serviceConfig = {
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 1";
          ExecStart = "${pkgs.coreutils}/bin/stdbuf -oL -eL ${diagPkg}/bin/diag-router -s 127.0.0.1:2500";
          Restart = "on-failure";
        };
      };

      # Holds /run/diag open for good and serves it on 127.0.0.1:2501, so
      # tools can connect and disconnect any number of times (the socat PTY
      # jams once its first reader closes it)
      diag-pty-bridge = {
        description = "Serve the diag PTY on 127.0.0.1:2501";
        wantedBy = [ "multi-user.target" ];
        after = [ "diag-router.service" ];
        requires = [ "diag-router.service" ];
        before = [ "rmtfs.service" ];
        serviceConfig = {
          # socat makes /run/diag once diag-router has connected to it
          ExecStartPre = pkgs.writeShellScript "diag-wait-pty" ''
            for _ in $(${pkgs.coreutils}/bin/seq 100); do
              [ -e /run/diag ] && exit 0
              ${pkgs.coreutils}/bin/sleep 0.1
            done
            exit 1
          '';
          ExecStart = "${pkgs.python3}/bin/python3 -u ${../tools/diag/pty-bridge.py} /run/diag 2501";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    } // lib.optionalAttrs cfg.bootCapture {
      diag-boot-capture = {
        description = "Record the modem's RF start (debug messages)";
        wantedBy = [ "multi-user.target" ];
        after = [ "diag-pty-bridge.service" ];
        requires = [ "diag-pty-bridge.service" ];
        # rmtfs gives the modem its EFS; the RF starts after that
        before = [ "rmtfs.service" ];
        serviceConfig = {
          StateDirectory = "diag";
          ExecStartPre = pkgs.writeShellScript "diag-wait-bridge" ''
            for _ in $(${pkgs.coreutils}/bin/seq 50); do
              ${pkgs.iproute2}/bin/ss -ltn | ${pkgs.gnugrep}/bin/grep -q ':2501 ' && exit 0
              ${pkgs.coreutils}/bin/sleep 0.2
            done
            exit 1
          '';
          # Named by boot id: the clock starts from 1970 at every boot
          ExecStart = pkgs.writeShellScript "diag-boot-capture" ''
            exec ${pkgs.python3}/bin/python3 -u ${../tools/diag/diag-f3-boot.py} \
              "/var/lib/diag/boot-$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/random/boot_id).bin" 180
          '';
          # Connected and masks sent before rmtfs may start
          ExecStartPost = "${pkgs.coreutils}/bin/sleep 3";
        };
      };
    };
  };
}
