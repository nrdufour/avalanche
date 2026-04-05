{ pkgs, ... }: {

  networking.hostName = "opi03";

  mySystem.networking.staticIP = {
    enable = true;
    mac = "c0:74:2b:ff:3c:0f";
    address = "10.1.0.22/24";
  };

  ## No need to add filesystem just yet (covered by nixos-rk3588)

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "03:00";
    flake = "git+https://forge.internal/nemo/avalanche.git";
  };
}
