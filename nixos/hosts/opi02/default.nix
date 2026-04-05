{ pkgs, ... }: {

  networking.hostName = "opi02";

  mySystem.networking.staticIP = {
    enable = true;
    mac = "c0:74:2b:ff:3b:93";
    address = "10.1.0.21/24";
  };

  ## No need to add filesystem just yet (covered by nixos-rk3588)

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "03:00";
    flake = "git+https://forge.internal/nemo/avalanche.git";
  };
}
