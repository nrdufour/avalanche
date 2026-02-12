{ 
  pkgs,
  config,
  ...
}: {
  # imports = [
  #   ./secrets.nix
  # ];

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
    hostName = "possum";
    # Setting the hostid for zfs
    hostId = "05176a3c";

    firewall = {
      enable = false;
      # allowedTCPPorts = [ 80 443 ];
    };
  };

  environment.systemPackages = with pkgs; [
      rclone
  ];

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "03:00";
    flake = "git+https://forge.internal/nemo/avalanche.git";
  };

}
