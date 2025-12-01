{
  config,
  nixpkgs,
  ...
}:
{
  imports = [
    "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
  ];

  image.fileName = "${config.networking.hostName}.img";
}