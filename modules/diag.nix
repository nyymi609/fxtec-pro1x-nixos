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
    };
  };
}
