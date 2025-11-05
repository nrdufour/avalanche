{ config, lib, pkgs, ... }:

{
  # Enable Tailscale with subnet routing for 10.1.0.0/24
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";  # Enable subnet routing
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
  };

  # Enable IP forwarding for subnet routing
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Configure Tailscale settings after startup
  systemd.services.tailscale-config = {
    description = "Configure Tailscale subnet routing and DNS";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tailscale-config" ''
        # Disable Tailscale DNS (this host IS the DNS server)
        ${pkgs.tailscale}/bin/tailscale set --accept-dns=false

        # Advertise subnet routes to tailnet
        ${pkgs.tailscale}/bin/tailscale set --advertise-routes=10.1.0.0/24
      '';
    };
  };

  # Open firewall for Tailscale
  networking.firewall = {
    allowedUDPPorts = [ 41641 ]; # Tailscale port
    trustedInterfaces = [ "tailscale0" ];
  };

  # Configure systemd-networkd to ignore Tailscale interface for wait-online
  systemd.network.networks."99-tailscale" = {
    matchConfig.Name = "tailscale*";
    linkConfig.RequiredForOnline = "no";
  };
}