{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.sensors;
  stateDir = "/var/lib/hexagonrpcd";
in
{
  options.pro1x.sensors = {
    enable = lib.mkEnableOption "ADSP (SSC) sensors through hexagonrpcd and iio-sensor-proxy";

    hexagonfs = lib.mkOption {
      type = lib.types.path;
      default = ../device/hexagonfs;
      description = ''
        Directory with `sensors/config`, `sensors/registry` and `sensors/sns_reg.conf`,
        copied from the phone's Android firmware (see device/hexagonfs/README.md).
      '';
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the sensor daemon at boot. With the registry served by this module the
        ADSP initialises its sensors without crashing. If a new firmware ever hangs
        the phone, set this to false and start the daemon by hand with
        `systemctl start pro1x-hexagonrpcd`.
      '';
    };

    hexagonrpcPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hexagonrpc.overrideAttrs (old: {
        version = "0.5.0-unstable-pr27";
        src = pkgs.fetchFromGitHub {
          owner = "linux-msm";
          repo = "hexagonrpc";
          rev = "40e50412812adce9dddc2be9a4510ebce05eef89";
          hash = "sha256-+VbVvPfKLgNrg3tliUFWG32Y/HPdNpD6XkaCHsU+DiY=";
        };
        patches = [ ../packages/hexagonrpc/sns-registry.patch ]
          ++ lib.optional cfg.probeUnknownInterfaces ../packages/hexagonrpc/probe.patch;
      });
      defaultText = lib.literalMD "nixpkgs `hexagonrpc` built from linux-msm/hexagonrpc pull request 27";
      description = "The hexagonrpc package providing hexagonrpcd. It must be able to write files.";
    };

    properties = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { hw_platform = "QRD"; };
      description = ''
        Platform properties the ADSP asks for by name (the ones Android keeps in sysfs
        or system properties). hw_platform selects which sensor configuration files
        apply ("QRD" picks the bengal_qrd_* ones, which list this phone's chips). Names
        not set here are looked up in /sys/devices/soc0.
      '';
    };

    probeUnknownInterfaces = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Debugging: make hexagonrpcd log (PROBE lines) the method, buffer counts and a hex
        dump of every call the ADSP makes to an interface it does not implement.
      '';
    };

    disableRecovery = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Turn off automatic ADSP restarts before starting the daemon. If the ADSP's sensor
        stack crashes, the automatic restart can loop and freeze the phone (the audio
        driver floods the log). With this on, a crash leaves the ADSP stopped (no audio
        until reboot) but the phone stays usable.
      '';
    };

    accelMountMatrix = lib.mkOption {
      type = lib.types.str;
      default = "-1, 0, 0; 0, -1, 0; 0, 0, 1";
      example = "1, 0, 0; 0, 1, 0; 0, 0, 1";
      description = ''
        Rotation from the sensor axes to the screen, in the udev ACCEL_MOUNT_MATRIX
        format used by iio-sensor-proxy. The default (x and y flipped, i.e. a 180 degree
        turn about the screen normal) was verified on a Pro1X: portrait, upside-down and
        both landscapes report correctly.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.iio-sensor-proxy ];
    services.dbus.packages = [ pkgs.iio-sensor-proxy ];
    services.udev.packages = [ pkgs.iio-sensor-proxy ];
    systemd.packages = [ pkgs.iio-sensor-proxy ];

    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="fastrpc-*", ENV{ACCEL_MOUNT_MATRIX}+="${cfg.accelMountMatrix}"
      # iio-sensor-proxy's own rule only enables the light and compass drivers on the
      # fastrpc device; the accelerometer and proximity drivers have to be asked for.
      SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"
    '';

    # iio-sensor-proxy is D-Bus activated; make it bring the daemon up and wait until the
    # ADSP's sensor service (QRTR service 400) exists, so it never starts into nothing.
    systemd.services.iio-sensor-proxy = {
      wants = lib.optional cfg.autostart "pro1x-hexagonrpcd.service";
      after = [ "pro1x-hexagonrpcd.service" ];
      serviceConfig.ExecStartPre = "-${pkgs.writeShellScript "pro1x-wait-ssc" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.qrtr ]}
        for _ in $(seq 1 60); do
          qrtr-lookup 2>/dev/null | grep -q '^ *400 ' && exit 0
          sleep 1
        done
        echo "SSC sensor service (QRTR 400) did not appear" >&2
      ''}";
    };

    systemd.services.pro1x-hexagonrpcd = {
      description = "Hexagon RPC daemon: serves the ADSP sensor configuration (SSC sensors)";
      wantedBy = lib.optional cfg.autostart "multi-user.target";
      before = [ "iio-sensor-proxy.service" ];
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "pro1x-hexagonrpcd-prepare" ''
          set -eu
          export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils ]}
          d=${stateDir}

          mkdir -p "$d/sensors"
          # config and sns_reg.conf are static: refresh them from the store every start.
          rm -rf "$d/sensors/config"
          cp -r ${cfg.hexagonfs}/sensors/config "$d/sensors/config"
          cp -f ${cfg.hexagonfs}/sensors/sns_reg.conf "$d/sensors/sns_reg.conf"
          # DSP-side modules the ADSP loads over FastRPC (Android's /vendor/dsp).
          rm -rf "$d/dsp"
          if [ -d ${cfg.hexagonfs}/dsp ]; then cp -r ${cfg.hexagonfs}/dsp "$d/dsp"; fi

          # The sensor framework keeps its registry (parsed config, calibration) in
          # sensors/persist/registry/{registry/,sns_reg_version,...} and rewrites it, so
          # it has to be a real, writable tree. Seed it from the packaged registry
          # whenever the packaged data changed (or on first run); keep it otherwise.
          rm -rf "$d/sensors/registry"   # old layout, read-only copy
          reg="$d/sensors/persist/registry"
          if [ "$(cat "$d/.seeded-from" 2>/dev/null)" != "${cfg.hexagonfs}" ] || [ ! -d "$reg/registry" ]; then
            rm -rf "$d/sensors/persist"
            mkdir -p "$reg"
            cp -r ${cfg.hexagonfs}/sensors/registry/. "$reg/registry/"
            echo "${cfg.hexagonfs}" > "$d/.seeded-from"
          fi
          chmod -R u+rwX "$d"
          rm -rf "$d/properties"; mkdir -p "$d/properties"
${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "          printf '%s\\n' ${lib.escapeShellArg v} > ${lib.escapeShellArg "${stateDir}/properties/${k}"}") cfg.properties)}
          echo "registry: $(find "$reg/registry" -type f | wc -l) files, $(find "$reg/registry" -type f -empty | wc -l) empty"
          ln -sfn /sys/devices/soc0 "$d/socinfo"
${lib.optionalString cfg.disableRecovery ''
          # Do not let a crashing ADSP restart in a loop (see the disableRecovery option).
          for rp in /sys/class/remoteproc/*; do
            [ "$(cat "$rp/name" 2>/dev/null)" = adsp ] && echo disabled > "$rp/recovery" || true
          done
''}
          # The ADSP remoteproc is registered late in boot; wait for its FastRPC node.
          for _ in $(seq 240); do
            [ -e /dev/fastrpc-adsp ] && exit 0
            sleep 1
          done
          echo "/dev/fastrpc-adsp did not appear" >&2
          exit 1
        '';
        ExecStart = "${cfg.hexagonrpcPackage}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R ${stateDir}";
        # A dead ADSP cannot be fixed by restarting the daemon; try a few times, then stop.
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 300;
        StateDirectory = "hexagonrpcd";
      };
      unitConfig = { StartLimitIntervalSec = 300; StartLimitBurst = 3; };
    };
  };
}
