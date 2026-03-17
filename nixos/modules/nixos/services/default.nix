{
  imports = [
    ./dns-static-records.nix
    ./logging.nix
    ./monitoring.nix
    ./reboot-required-check.nix
    ./k3s
    ./nfs.nix
    ./minio.nix
    ./samba.nix
    ./sentinel.nix
  ];
}