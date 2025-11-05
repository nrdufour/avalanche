{ config, lib, pkgs, ... }:

{
  # Enable Tailscale - DNS server only (no subnet routing)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";  # Client mode only - NO subnet routing
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
  };

  # Disable Tailscale DNS - this host IS the DNS server
  systemd.services.tailscale-disable-dns = {
    description = "Disable Tailscale DNS - this host provides DNS";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale set --accept-dns=false";
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