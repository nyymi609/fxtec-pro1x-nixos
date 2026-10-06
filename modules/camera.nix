{ config, lib, pkgs, ... }:

# Cameras through PipeWire + libcamera (software ISP): the patched libcamera knows the
# S5K4H7 and IMX582 sensors. Apps: Snapshot (GNOME) and cameractr (focus/exposure controls).
{
  options.pro1x.camera.enable = lib.mkEnableOption "camera stack (libcamera with the Pro1X sensors)";

  config = lib.mkIf config.pro1x.camera.enable {
    # The camera device is created inside WirePlumber, which loads libcamera through
    # PipeWire's SPA plugin. Point it at the patched libcamera (same version and ABI
    # as the stock one) instead of rebuilding PipeWire and everything above it.
    systemd.user.services.wireplumber.environment.LD_LIBRARY_PATH = "${pkgs.pro1x-libcamera}/lib";

    # XDG user dirs: without ~/.config/user-dirs.dirs apps like Snapshot have no
    # Pictures/Videos folder to save into. Created once, never overwritten.
    systemd.tmpfiles.rules =
      let
        u = config.users.users.nixos;
        own = "${u.name} ${u.group}";
        dirs = ''XDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_DOWNLOAD_DIR="$HOME/Downloads"\nXDG_DOCUMENTS_DIR="$HOME/Documents"\nXDG_MUSIC_DIR="$HOME/Music"\nXDG_PICTURES_DIR="$HOME/Pictures"\nXDG_VIDEOS_DIR="$HOME/Videos"\n'';
      in
      [ "d ${u.home}/.config 0755 ${own} -" ]
      ++ map (d: "d ${u.home}/${d} 0755 ${own} -") [ "Desktop" "Downloads" "Documents" "Music" "Pictures" "Videos" ]
      ++ [ "f ${u.home}/.config/user-dirs.dirs 0644 ${own} - ${dirs}" ];

    environment.systemPackages = with pkgs; [
      pro1x-libcamera # `cam`
      pro1x-cameractrl # run: cameractr
      v4l-utils # media-ctl, v4l2-ctl
      snapshot
    ];
  };
}
