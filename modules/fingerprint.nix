{ config, lib, pkgs, ... }:

# The fingerprint reader (packages/fingerprint): the QSEECOM TEE driver
# (module qseecomtee) loads the stock trusted app mafp, qsee-supplicant keeps
# its templates, pro1x-fpd talks to it on /run/pro1x-fpd.sock:
#   pro1x-fpd enroll NAME     14 touches, covering the whole sensor
#   pro1x-fpd list | remove ID | rename ID NAME
#   pro1x-fpd identify        "nomatch"... until "match ID NAME" (lock screens)
# Members of the users group may connect. The sensor is read only during an
# identify or enrolment, and identify pauses while the panel is off.
# Ported from fxtec-pro1x-guix, where enrolment and unlock work.
#
# PAM (pamServices, e.g. sudo): a finger first, like pam_fprintd elsewhere
# (pam_pro1x_fpd: one identify for up to pamTimeout seconds; ctrl+c, the
# timeout or no daemon go on to the password).
let
  cfg = config.pro1x.fingerprint;
  fp = pkgs.pro1x-fingerprint;
in
{
  options.pro1x.fingerprint = {
    enable = lib.mkEnableOption ''
      the fingerprint reader (proprietary trusted app from the LineageOS
      vendor blobs; needs the kernel with the QSEECOM patches)'';

    pamServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "sudo" ];
      example = [ "sudo" "polkit-1" ];
      description = ''
        PAM services that take a finger before the password. Not "login":
        the lock screen checks the password through it and runs its own
        identify.
      '';
    };

    pamTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds to wait for a finger before the password.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Where pam_fprintd would be, before the password
    security.pam.services = lib.genAttrs cfg.pamServices (service: {
      rules.auth.pro1x-fingerprint = {
        order = config.security.pam.services.${service}.rules.auth.fprintd.order + 1;
        control = "sufficient";
        modulePath = "${fp.pam-pro1x-fpd}/lib/security/pam_pro1x_fpd.so";
        args = [ "timeout=${toString cfg.pamTimeout}" ];
      };
    });

    hardware.firmware = [ fp.mafp-firmware ];
    environment.systemPackages = [ fp.pro1x-fpd ];

    systemd.services = {
      qsee-supplicant = {
        description = "Answer QSEE trusted apps' listener requests";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-udev-settle.service" ];
        # Not on an older booted kernel (after a switch, before the reboot):
        # it has no qseecomtee, and the unit fails here instead of hanging
        # on a driver without moWerk's fixes
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "main";
          ExecStartPre = "${pkgs.kmod}/bin/modprobe qseecomtee";
          ExecStart = "${fp.qsee-supplicant}/bin/qsee-supplicant --state-dir /var/lib/qsee-supplicant";
          StateDirectory = "qsee-supplicant";
          StateDirectoryMode = "0700";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      qsee-app-loader-mafp = {
        description = "Keep the fingerprint trusted app, mafp, loaded";
        wantedBy = [ "multi-user.target" ];
        requires = [ "qsee-supplicant.service" ];
        after = [ "qsee-supplicant.service" ];
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "main";
          ExecStart = "${fp.qsee-supplicant}/bin/qsee-app-loader mafp";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      pro1x-fpd = {
        description = "Enrol and match fingerprints on the mafp app";
        wantedBy = [ "multi-user.target" ];
        # INIT must be the first command of an app instance: a new pro1x-fpd
        # needs a freshly loaded mafp, so they restart together
        bindsTo = [ "qsee-app-loader-mafp.service" ];
        after = [ "qsee-app-loader-mafp.service" ];
        serviceConfig = {
          ExecStart = "${fp.pro1x-fpd}/bin/pro1x-fpd --daemon";
          # Its names of the fingers (the templates are the supplicant's)
          StateDirectory = "pro1x-fpd";
          StateDirectoryMode = "0700";
        };
      };
    };
  };
}
