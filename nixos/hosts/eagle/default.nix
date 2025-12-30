{ pkgs, ... }: {
  imports = [
    # ./gitea
    ./forgejo
  ];

  # Note: this *MUST* be set, otherwise nothing will be
  # present at boot and you end up in emergency mode ...
  mySystem = {
    system.zfs = {
      enable = true;
      mountPoolsAtBoot = [ "tank" ];
    };
  };

  fileSystems = {
    "/" =
      {
        device = "/dev/disk/by-label/NIXOS_SD";
        fsType = "ext4";
      };

    "/boot/firmware" =
      {
        device = "/dev/disk/by-label/FIRMWARE";
        fsType = "vfat";
      };

  };

  networking = {
    hostName = "eagle";
    # Setting the hostid for zfs
    hostId = "8425e349";

    firewall = {
      enable = true;
      allowedTCPPorts = [ 80 443 ];
    };
  };

  # Limit ZFS ARC to prevent memory exhaustion on 7.6GB system
  # Reserves ~5GB for Forgejo, PostgreSQL, Docker, git operations
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=2147483648
  '';

  # Increase socket buffer sizes to fix Docker broken pipe errors
  # during buildkit operations with heavy output (multi-arch builds, QEMU emulation)
  # See: forgejo-runner-upgrade-plan.md investigation
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 16777216;     # 16MB (was 208KB)
    "net.core.wmem_max" = 16777216;     # 16MB (was 208KB)
    "net.core.rmem_default" = 262144;   # 256KB (was 208KB)
    "net.core.wmem_default" = 262144;   # 256KB (was 208KB)
  };

  sops.defaultSopsFile = ../../../secrets/eagle/secrets.sops.yaml;

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "01:00";
    flake = "git+https://forge.internal/nemo/avalanche.git";
  };
}
