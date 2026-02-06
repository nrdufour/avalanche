{ config, pkgs, ... }:
{
  sops.secrets = {
    forgejo_runner_token = { };
  };

  environment.systemPackages = with pkgs; [
    cachix
    lazydocker
    lazygit
    git
    nodejs_24 # required by actions such as checkout
    openssl
  ];

  # For cachix
  nix.settings.trusted-users = [ "root" "gitea-runner" ];

  # Ensure runner home directories are accessible by containers
  systemd.tmpfiles.rules = [
    "d /var/lib/gitea-runner/first/home 0755 gitea-runner gitea-runner -"
    "d /var/lib/gitea-runner/second/home 0755 gitea-runner gitea-runner -"
  ];

  # For the runner
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
    };
    # Enable containerd image store for multi-platform builds (--platform linux/amd64,linux/arm64)
    # without needing docker/setup-buildx-action (which has known issues with Forgejo runners).
    # Note: existing images will need to be re-pulled after this change.
    daemon.settings = {
      features = {
        containerd-snapshotter = true;
      };
    };
  };

  environment.etc."buildkit/buildkitd.toml".text = ''
    # Disable Container Device Interface (CDI) to prevent GPU detection
    # Hawk has no discrete GPU, and CDI auto-detection causes container start failures
    [cdi]
      disabled = true

    [registry."forge.internal"]
      http = true
      insecure = true
      ca=["/etc/ssl/certs/ca-certificates.crt"]
  '';

  #
  # Ref: https://github.com/colonelpanic8/dotfiles/blob/03346eeaeb68633a50d6687659cbcdf46d243d36/nixos/forgejo-runner.nix#L20
  # 

  services.gitea-actions-runner = {
    # It's forgejo, not gitea ;-)
    # Using standard package (v12.4.0) - x86_64 is well supported upstream
    package = pkgs.forgejo-runner;

    instances = {

      first = let gitea-runner-directory = "/var/lib/gitea-runner/first"; in {
        settings = {
          # log = {
          #   level = "trace";      # Runner process trace output
          #   job_level = "trace";  # Job logs visible in Forgejo UI
          # };
          cache = {
            enabled = true;
          };
          # Both the container and host workdir parent has to be fully specified
          # to avoid some issues with relative path in typescript module resolution.
          container = {
            workdir_parent = "${gitea-runner-directory}/workspace";

            ## Allow some path to be mounted
            ## See https://gitea.com/gitea/act_runner/src/branch/main/internal/pkg/config/config.example.yaml#L87
            valid_volumes = [
              "/etc/ssl/certs/*"
              "/var/lib/gitea-runner/first/home"
            ];

            # Mount the ssl certs directly
            options = "--volume /etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro --volume /var/lib/gitea-runner/first/home:/var/lib/gitea-runner/first/home";
          };
          host = {
            workdir_parent = "${gitea-runner-directory}/action-cache-dir";
          };
          runner = {
            envs = {
              # This is needed because the user 'forgejo-runner' is dynamic
              # and therefore has no home directory.
              # Without HOME, docker will try to create /.docker directory instead.
              HOME = "${gitea-runner-directory}/home";

              # Trying to set the timezone properly
              TZ = "America/New_York";
            };
          };
        };
        enable = true;
        name = "first";
        url = "https://forge.internal/";
        tokenFile = config.sops.secrets.forgejo_runner_token.path;
        labels = [
          "native:host"
          "docker:docker://node:24-bookworm"
        ];
        hostPackages = with pkgs; [
          bash
          coreutils
          curl
          gawk
          git-lfs
          nixVersions.stable
          gitFull
          gnused
          nodejs_24
          wget
          docker
          gnutar
          gzip
        ];
      };

      second = let gitea-runner-directory = "/var/lib/gitea-runner/second"; in {
        settings = {
          # log = {
          #   level = "trace";      # Runner process trace output
          #   job_level = "trace";  # Job logs visible in Forgejo UI
          # };
          cache = {
            enabled = true;
          };
          # Both the container and host workdir parent has to be fully specified
          # to avoid some issues with relative path in typescript module resolution.
          container = {
            workdir_parent = "${gitea-runner-directory}/workspace";
            
            ## Allow some path to be mounted
            ## See https://gitea.com/gitea/act_runner/src/branch/main/internal/pkg/config/config.example.yaml#L87
            valid_volumes = [
              "/etc/ssl/certs/*"
              "/var/lib/gitea-runner/second/home"
            ];

            # Mount the ssl certs directly
            options = "--volume /etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro --volume /var/lib/gitea-runner/second/home:/var/lib/gitea-runner/second/home";
          };
          host = {
            workdir_parent = "${gitea-runner-directory}/action-cache-dir";
          };
          runner = {
            envs = {
              # This is needed because the user 'forgejo-runner' is dynamic
              # and therefore has no home directory.
              # Without HOME, docker will try to create /.docker directory instead.
              HOME = "${gitea-runner-directory}/home";
              
              # Trying to set the timezone properly
              TZ = "America/New_York";
            };
          };
        };
        enable = true;
        name = "second";
        url = "https://forge.internal/";
        tokenFile = config.sops.secrets.forgejo_runner_token.path;
        labels = [
          "native:host"
          "docker:docker://node:24-bookworm"
        ];
        hostPackages = with pkgs; [
          bash
          coreutils
          curl
          gawk
          git-lfs
          nixVersions.stable
          gitFull
          gnused
          nodejs_24
          wget
          docker
          gnutar
          gzip
        ];
      };

    };
  };
}
