{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.diag;
in
{
  options.pro1x.diag.enable = lib.mkEnableOption
    "Qualcomm DIAG router (modem diagnostics over rpmsg, for RF/signalling debugging). Untested";

  config = lib.mkIf cfg.enable {
    # CONFIG_RPMSG_CHAR / CONFIG_RPMSG_CTRL are built as modules in the Pro1X kernel.
    boot.kernelModules = [ "rpmsg_char" "rpmsg_ctrl" ];
    environment.systemPackages = [ pkgs.pro1x-diag ];

    systemd.services.diag-router = {
      description = "Qualcomm DIAG router";
      wantedBy = [ "multi-user.target" ];
      after = [ "rmtfs.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.pro1x-diag}/bin/diag-router";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
