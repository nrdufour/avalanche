{ pkgs, config, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  # Systemd-boot EFI
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking = {
    hostName = "muninn";
    firewall.enable = true;
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Headless — disable desktop services
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
