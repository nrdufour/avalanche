{
  pkgs,
  ...
}: {
  imports = [
    ./local-pg.nix
    ./forgejo.nix
    ./forgejo-runner.nix
    ./forgejo-rclone.nix
    ./forgejo-restic-remote.nix
    ./forgejo-container-cleanup.nix
  ];
}