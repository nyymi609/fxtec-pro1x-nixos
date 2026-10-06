{ config, lib, pkgs, ... }:

# Hardware keyboard: Finnish layout (the keycaps are Finnish) and the Fn layer from
# device/input/keyd.conf. The kernel driver is in device/kernel/patches/pro1x-keyboard.patch.
{
  options.pro1x.keyboard.enable = lib.mkEnableOption "Pro1X keyboard layout and Fn layer" // { default = true; };

  config = lib.mkIf config.pro1x.keyboard.enable {
    # "nodeadkeys": the ¨ ´ keys type ¨ ^ ~ ` ´ directly, as the Fn legends on the
    # keycaps show, instead of waiting for a letter.
    services.xserver.xkb.layout = "fi";
    services.xserver.xkb.variant = "nodeadkeys";

    services.keyd.enable = true;
    environment.etc."keyd/default.conf".source = ../device/input/keyd.conf;
    systemd.services.keyd.restartTriggers = [ ../device/input/keyd.conf ];
    environment.systemPackages = [ pkgs.keyd ]; # `keyd monitor` shows what each key sends
  };
}
