{ config, lib, pkgs, ... }:

{
  # Tailscale secret
  sops.secrets."tailscale_auth_key" = { };

  # Enable Tailscale for remote access to services
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";  # Client mode only (no routing)
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
  };

  # Disable Tailscale DNS - critical infrastructure should use local DNS
  systemd.services.tailscale-disable-dns = {
    description = "Disable Tailscale DNS for critical infrastructure";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale set --accept-dns=false";
    };
  };

  # Explicitly set DNS servers (don't rely on Tailscale)
  networking.nameservers = [ "10.0.0.1" ];  # routy
  networking.search = [ "internal" ];

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
