{ inputs, pkgs, config, ... }: {
  imports = [
    ./tailscale.nix
  ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };

    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
    };

    "/srv" = {
      device = "/dev/disk/by-id/usb-Samsung_Flash_Drive_FIT_0323222060006409-0:0";
      fsType = "ext4";
    };
  };

  networking.hostName = "lobster";

  networking.firewall = {
    enable = true;
    # SSH and all other ports are accessible via Tailscale (trustedInterfaces in tailscale.nix)
  };

  sops.defaultSopsFile = ../../../secrets/lobster/secrets.sops.yaml;

  # Agent runner tools
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.oh-my-opencode
  ];

  # Log shipping enabled via global.nix
  # Auto-upgrade disabled — lobster is a testing/agent-runner machine
  system.autoUpgrade.enable = false;
}
