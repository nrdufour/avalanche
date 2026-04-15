{ inputs, pkgs, config, ... }: {
  imports = [
    ./tailscale.nix
    ./hermes.nix
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

  networking.hostName = "chipmunk";

  networking.firewall = {
    enable = true;
    # SSH and all other ports are accessible via Tailscale (trustedInterfaces in tailscale.nix)
  };

  mySystem.networking.staticIP = {
    enable = true;
    mac = "d8:3a:dd:17:1e:1b";
    address = "10.1.0.99/24";
    dns = [ "10.0.0.1" ];
  };

  sops.defaultSopsFile = ../../../secrets/chipmunk/secrets.sops.yaml;

  # Agent runner tools — claude-code for interactive coding,
  # hermes-agent (imported above) for fire-and-forget tasks.
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
  ];

  # Log shipping enabled via global.nix
  # Auto-upgrade disabled — chipmunk is a testing/agent-runner machine
  system.autoUpgrade.enable = false;
}
