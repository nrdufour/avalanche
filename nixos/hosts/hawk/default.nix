{ pkgs, config, ... }: {

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./secrets.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # RTL8125 network driver configuration
  boot.extraModulePackages = [ config.boot.kernelPackages.r8125 ];
  boot.blacklistedKernelModules = [ "r8169" ];

  # Constraining the ZFS memory usage for ARC
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=4294967296
  '';

  networking = {
    hostName = "hawk";
    # Setting the hostid for zfs
    hostId = "b6956419";

    firewall = {
      enable = false;
      # allowedTCPPorts = [ 80 443 ];
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Disable desktop environment (headless server)
  services.xserver.enable = false;
  services.displayManager.gdm.enable = false;
  services.desktopManager.gnome.enable = false;
  services.printing.enable = false;
  services.pipewire.enable = false;
  services.pulseaudio.enable = false;
  security.rtkit.enable = false;

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "03:00";
    flake = "git+https://forge.internal/nemo/avalanche.git";
  };
}
