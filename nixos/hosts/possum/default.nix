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

    "/data" =
      {
        device = "/dev/disk/by-label/POSSUM_DATA";
        fsType = "ext4";
      };
  };

  networking = {
    hostName = "possum";

    firewall = {
      enable = false;
      # allowedTCPPorts = [ 80 443 ];
    };
  };

  services.victoriametrics = {
    enable = true;
    retentionPeriod = "10y";
  };

  # Store VM data on the SSD rather than the SD card
  fileSystems."/var/lib/victoriametrics" = {
    device = "/data/victoriametrics";
    options = [ "bind" ];
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
