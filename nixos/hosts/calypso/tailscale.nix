{ config, lib, pkgs, ... }:

{
  # Enable Tailscale for remote access
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";  # Client mode only (no routing)
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
  };

  # Configure Tailscale settings after startup
  systemd.services.tailscale-config = {
    description = "Configure Tailscale to reject subnet routes";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tailscale-config" ''
        # Don't accept subnet routes from other nodes
        ${pkgs.tailscale}/bin/tailscale set --accept-routes=false
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
