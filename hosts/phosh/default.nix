{ lib, pkgs, ... }:

# Phosh (phoc compositor + stevia on-screen keyboard), calls, SMS and the camera.
{
  imports = [ ../minimal ];

  pro1x.camera.enable = true;

  services.xserver.desktopManager.phosh = {
    enable = true;
    user = "nixos";
    group = "users";
    phocConfig.outputs.DSI-1.scale = 2; # 1080x2160 panel
  };
  systemd.defaultUnit = lib.mkDefault "graphical.target";

  # Hardware keyboard layout for phoc and the on-screen keyboard.
  programs.dconf.enable = true;
  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/input-sources".sources = [
        (lib.gvariant.mkTuple [ "xkb" "fi+nodeadkeys" ])
      ];
    }
  ];

  # Chatty links libolm (Matrix end-to-end encryption), which nixpkgs marks insecure.
  # Only the Matrix chat feature is affected, not SMS/MMS.
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];
  programs.calls.enable = true; # dialer: ModemManager + callaudiod

  environment.systemPackages = with pkgs; [
    gnome-console
    firefox
    # nixpkgs' chatty wrapper fails with no libpurple plugins (empty
    # PURPLE_PLUGIN_PATH); there are none here, so drop that wrapper arg.
    (chatty.overrideAttrs (_: { preFixup = ""; }))
  ];
}
