{ pkgs, config, inputs, ... }: {
  imports = [
    ./hardware-configuration.nix
    ./hermes.nix
  ];

  sops.defaultSopsFile = ../../../secrets/muninn/secrets.sops.yaml;

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
  # On muninn the issue triggers during early stage 2 boot (unlike
  # hawk where it only triggers under QEMU load), so we need to
  # disable boost *before* userspace starts. Switching the AMD P-state
  # driver to passive mode via kernel param makes the boost control
  # take effect at kernel init time; the tmpfiles rule is kept as
  # belt-and-suspenders for the running system.
  # See docs/troubleshooting/muninn-ser5-cold-boot-reboot.md.
  boot.kernelParams = [ "amd_pstate=passive" ];
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
  ];

  networking = {
    hostName = "muninn";
    firewall.enable = true;
  };

  mySystem.networking.staticIP = {
    enable = true;
    mac = "78:55:36:06:b3:d0";
    address = "10.1.0.92/24";
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Agent runner tools — claude-code for interactive coding,
  # hermes-agent (imported above) for fire-and-forget tasks.
  environment.systemPackages = [
    pkgs.htop
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
  ];

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
