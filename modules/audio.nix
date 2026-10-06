{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.audio;
  audio = pkgs.pro1x-audio;

  # WirePlumber and PipeWire must see the merged UCM tree (stock profiles + ours).
  ucmDir = "${pkgs.symlinkJoin {
    name = "alsa-ucm-conf-pro1x";
    paths = [ audio pkgs.alsa-ucm-conf ];
  }}/share/alsa/ucm2";
in
{
  options.pro1x.audio.enable = lib.mkEnableOption "PipeWire and the Pro1X audio profile";

  config = lib.mkIf cfg.enable {
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
      wireplumber.configPackages = [ audio ];
    };
    security.rtkit.enable = true;

    environment.variables.ALSA_CONFIG_UCM2 = lib.mkForce ucmDir;
    systemd.user.services = {
      pipewire.environment.ALSA_CONFIG_UCM2 = lib.mkForce ucmDir;
      wireplumber = {
        environment.ALSA_CONFIG_UCM2 = lib.mkForce ucmDir;
        serviceConfig.ExecStartPre = [ "${audio}/bin/pro1x-audio-init" ];
      };

      # started and stopped by the "Voice Call" UCM verb (pro1x-voice-call start|stop).
      pro1x-voicepcm = {
        description = "Pro1X voice call session (VoiceMMode1 stream + codec keep-alive)";
        serviceConfig = {
          ExecStart = "${audio}/bin/pro1x-voice-call run";
          Restart = "no";
        };
      };
    };

    environment.systemPackages = with pkgs; [
      audio # pro1x-voicepcm, pro1x-voice-call, pro1x-audio-init
      alsa-utils
      pulseaudio # pactl
    ];
  };
}
