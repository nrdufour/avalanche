{ pkgs, config, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  # Systemd-boot EFI
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # RTL8125 network driver — Beelink SER5 ships the Realtek RTL8125
  # 2.5Gbps NIC which is flaky under the in-tree r8169 driver. Use the
  # vendor r8125 out-of-tree module instead (same fix as hawk).
  boot.extraModulePackages = [ config.boot.kernelPackages.r8125 ];
  boot.blacklistedKernelModules = [ "r8169" ];

  # Disable CPU turbo boost — Beelink SER5 has a known power delivery
  # issue where rapid core state transitions cause instant reboots.
  # See docs/troubleshooting/hawk-qemu-arm64-reboots.md and
  # https://bbs.bee-link.com/d/9082-ser5-max-6800u-crashes.
  # On muninn the issue triggers during early stage 2 boot (unlike
  # hawk where it only triggered under QEMU load), so we need to
  # disable boost before userspace starts. Switch to amd_pstate=passive
  # so that the no_turbo kernel parameter actually takes effect, then
  # also set it via tmpfiles as a belt-and-suspenders for the running
  # system.
  boot.kernelParams = [ "amd_pstate=passive" ];
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
  ];

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
