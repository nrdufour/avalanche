{ lib, pkgs, config, ... }:

{
  # Enable Sentinel gateway management tool
  mySystem.services.sentinel = {
    enable = true;

    # Server settings
    host = "127.0.0.1";
    port = 8080;

    # Authentication
    auth.local = {
      enable = true;
      users = [
        {
          username = "admin";
          passwordHashFile = config.sops.secrets."sentinel_admin_password_hash".path;
          role = "admin";
        }
      ];
    };

    # Session configuration
    session = {
      secretFile = config.sops.secrets."sentinel_session_secret".path;
      lifetime = "24h";
      secure = true;  # Requires HTTPS (nginx handles this)
    };

    # Services to monitor
    services.systemd = [
      {
        name = "kea-dhcp4-server";
        displayName = "Kea DHCP4";
        description = "DHCP server for IP address assignment";
        canRestart = true;
      }
      {
        name = "kea-dhcp-ddns-server";
        displayName = "Kea DDNS";
        description = "Dynamic DNS updates from DHCP";
        canRestart = true;
      }
      {
        name = "knot";
        displayName = "Knot DNS";
        description = "Authoritative DNS server";
        canRestart = true;
      }
      {
        name = "kresd@1";
        displayName = "Kresd Resolver";
        description = "Recursive DNS resolver";
        canRestart = true;
      }
      {
        name = "adguardhome";
        displayName = "AdGuard Home";
        description = "DNS filtering and ad blocking";
        canRestart = true;
      }
      {
        name = "nginx";
        displayName = "Nginx";
        description = "Reverse proxy";
        canRestart = true;
      }
      {
        name = "tailscaled";
        displayName = "Tailscale";
        description = "VPN subnet router";
        canRestart = false;  # Don't allow restart - would disconnect users
      }
    ];

    # Kea DHCP collector
    collectors.kea = {
      leaseFile = "/var/lib/kea/kea-leases4.csv";
      controlSocket = "/run/kea/kea-dhcp4-ctrl.sock";
    };

    # AdGuard Home collector
    collectors.adguard = {
      apiUrl = "http://127.0.0.1:3003";
      username = "";  # No auth needed for local access
    };

    # WAN status monitoring
    collectors.wan = {
      enable = true;
      latencyTargets = [ "1.1.1.1" "8.8.8.8" ];
      cacheDuration = "5m";
    };

    # Tailscale peer monitoring
    collectors.tailscale.enable = true;

    # Bandwidth history tracking
    collectors.bandwidth = {
      enable = true;
      sampleRate = "5s";
      retention = "24h";
    };

    # LLDP neighbor discovery
    collectors.lldp.enable = true;

    # System resource monitoring
    collectors.system.diskMountPoints = [ "/" "/srv" ];

    # Network interfaces to monitor
    collectors.network.interfaces = [
      {
        name = "wan0";
        displayName = "WAN";
        description = "External internet connection";
      }
      {
        name = "lan0";
        displayName = "LAN";
        description = "Primary internal network";
      }
      {
        name = "lab0";
        displayName = "Lab0";
        description = "Lab/K3s network (10.1.0.0/24)";
      }
      {
        name = "lab1";
        displayName = "Lab1";
        description = "Secondary lab network (10.2.0.0/24)";
      }
      {
        name = "tailscale0";
        displayName = "Tailscale";
        description = "VPN interface";
      }
    ];

    # Logging
    logging = {
      level = "info";
      format = "json";
    };

    # Nginx reverse proxy
    nginx = {
      enable = true;
      hostname = "sentinel.internal";
    };
  };

  # Ensure ACME cert for sentinel.internal
  security.acme.certs."sentinel.internal" = { };
}
