{ pkgs, ... }:

# Smallest useful system: USB ethernet + serial console, Wi-Fi/modem, audio, keyboard,
# SSH. The phosh host builds on this. Change the password and add your SSH
# key before relying on it.
{
  networking.hostName = "pro1x";
  networking.networkmanager.enable = true;

  # USB serial gadget (ttyGS0) as a rescue console.
  pro1x.serial.enable = true;
  pro1x.modem.enable = true; # Wi-Fi firmware goes through the modem, see modules/modem.nix
  pro1x.audio.enable = true;

  # Keep kernel errors in dmesg but off the serial/tty consoles.
  boot.consoleLogLevel = 3;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # Let the nixos user push store paths (nix copy) over USB ethernet.
  nix.settings.trusted-users = [ "root" "nixos" ];

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "input" "audio" "feedbackd" ];
    initialPassword = "nixos"; # CHANGE ME
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA..." ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true; # tighten after adding a key
  };

  environment.systemPackages = with pkgs; [ vim git usbutils iw libinput evtest i2c-tools ];

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
}
