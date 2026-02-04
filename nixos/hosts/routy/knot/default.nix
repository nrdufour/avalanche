{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./dns.nix
    ./resolver.nix
    ./static-records.nix
  ];
}