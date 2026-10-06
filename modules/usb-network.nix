{ config, lib, ... }:

# USB gadget networking: the phone shows up on the PC as a serial port AND an
# Ethernet adapter (kernel g_cdc). The phone is 172.16.42.1 and runs a DHCP
# server on the link, so the PC configures itself; then:
#
#   ssh nixos@172.16.42.1
#   nix copy --to ssh-ng://nixos@172.16.42.1 ./result
let
  cfg = config.pro1x.usbNetwork;
in
{
  options.pro1x.usbNetwork = {
    enable = lib.mkEnableOption "Ethernet over the USB gadget (usb0, 172.16.42.1/24 with DHCP server)" // { default = true; };
    address = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.1/24";
    };
  };

  config = lib.mkIf cfg.enable {
    # Fixed MACs so the interface name on the PC (enx0250...) does not change per boot.
    boot.kernelParams = [
      "g_cdc.host_addr=02:50:31:e8:00:01"
      "g_cdc.dev_addr=02:50:31:e8:00:02"
    ];

    systemd.network.enable = true;
    systemd.network.wait-online.enable = false;
    systemd.network.networks."20-usb-gadget" = {
      matchConfig.Name = "usb0";
      address = [ cfg.address ];
      networkConfig.DHCPServer = true;
      dhcpServerConfig = {
        PoolOffset = 10;
        PoolSize = 10;
        EmitDNS = false;
        EmitRouter = false;
      };
      linkConfig.RequiredForOnline = "no";
    };

    # NetworkManager (wifi/modem) must leave the gadget link alone.
    networking.networkmanager.unmanaged = [ "interface-name:usb0" ];
    # Development link: trust it (ssh, nix copy, debugging).
    networking.firewall.trustedInterfaces = [ "usb0" ];
  };
}
