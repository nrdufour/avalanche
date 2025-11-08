{ config, pkgs, ... }: {
    imports = [
        # Include the results of the hardware scan
        ./hardware-configuration.nix

        # Tailscale mesh VPN
        ./tailscale.nix

        # User-specific personalities
        # (core personalities imported via role-workstation.nix)
        ../../personalities/ham
        ../../personalities/chat
        ../../personalities/backups
        ../../personalities/knowledge
    ];

    networking.hostName = "calypso";

    # Allow SSH through firewall
    services.openssh.openFirewall = true;

    sops = {
        defaultSopsFile = ../../../secrets/calypso/secrets.sops.yaml;
        secrets = {
            "tailscale_auth_key" = {};
            "backups/localndufour/repository" = {};
            "backups/localndufour/password" = {};
            "backups/localndufour/env" = {};
        };
    };

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "24.05";
}