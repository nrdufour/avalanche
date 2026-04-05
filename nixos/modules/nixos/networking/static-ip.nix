{ lib, config, ... }:

let
  cfg = config.mySystem.networking.staticIP;
in
{
  options.mySystem.networking.staticIP = {
    enable = lib.mkEnableOption "Static IP via systemd-networkd (MAC-matched)";

    mac = lib.mkOption {
      type = lib.types.str;
      description = "MAC address of the network interface to configure.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      description = "Static IPv4 address with prefix length (e.g. 10.1.0.30/24).";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.1.0.1";
      description = "Default gateway.";
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "10.0.0.54" ];
      description = "DNS server addresses.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.useDHCP = lib.mkForce false;
    networking.useNetworkd = true;

    systemd.network = {
      enable = true;

      networks."30-static" = {
        matchConfig.MACAddress = cfg.mac;
        address = [ cfg.address ];
        gateway = [ cfg.gateway ];
        dns = cfg.dns;
        networkConfig = {
          DHCP = "no";
          DNSDefaultRoute = true;
        };
        domains = [ "internal" ];
      };
    };
  };
}
