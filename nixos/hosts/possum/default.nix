{
  pkgs,
  config,
  lib,
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

  mySystem.networking.staticIP = {
    enable = true;
    mac = "dc:a6:32:f9:22:5f";
    address = "10.1.0.60/24";
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

  services.victorialogs = {
    enable = true;
  };

  # DynamicUser=true (the module default) can't migrate the StateDirectory when it's
  # a bind mount (different device). Override to match how victoriametrics is run.
  systemd.services.victorialogs.serviceConfig.DynamicUser = lib.mkForce false;

  # Store VictoriaLogs data on the SSD rather than the SD card
  fileSystems."/var/lib/victorialogs" = {
    device = "/data/victorialogs";
    options = [ "bind" ];
  };

  security.acme.certs."vm.internal" = { };
  security.acme.certs."vl.internal" = { };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."vm.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass = "http://localhost:8428";
    };

    virtualHosts."vl.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass = "http://localhost:9428";
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
