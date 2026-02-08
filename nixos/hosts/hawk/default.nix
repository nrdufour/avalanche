{ pkgs, config, ... }: {

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./secrets.nix
      ./forgejo
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # RTL8125 network driver configuration
  boot.extraModulePackages = [ config.boot.kernelPackages.r8125 ];
  boot.blacklistedKernelModules = [ "r8169" ];

  # Register QEMU binfmt for ARM64 emulation (needed for multi-platform Docker builds)
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  # Fix-binary flag loads the QEMU interpreter at registration time, making it
  # available inside Docker containers that don't have the /run/binfmt path.
  boot.binfmt.registrations.aarch64-linux.fixBinary = true;

  # Disable CPU turbo boost to prevent crashes during QEMU ARM64 emulation.
  # The Beelink SER5 Max has a known power delivery issue where rapid core
  # state transitions (common in QEMU workloads) cause instant reboots.
  # See: docs/troubleshooting/hawk-qemu-arm64-reboots.md
  # See: https://bbs.bee-link.com/d/9082-ser5-max-6800u-crashes
  # Note: kernel param amd_pstate.no_boost=1 doesn't work with amd-pstate-epp driver
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
  ];

  networking = {
    hostName = "hawk";
    # Unique host identifier (kept for consistency)
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
