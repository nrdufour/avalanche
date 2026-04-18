{ config, inputs, ... }: {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;

    # Host-side `hermes` wrapper on PATH. Routes into the container
    # for interactive users listed in container.hostUsers below.
    addToSystemPackages = true;

    environmentFiles = [ config.sops.secrets."hermes-env".path ];

    # Container mode gives Hermes a writable Ubuntu layer where it can
    # apt/pip/npm install arbitrary tools without polluting NixOS. The
    # docker backend auto-enables virtualisation.docker via mkDefault.
    # x86_64 on muninn means Chrome for Testing works natively — no
    # ARM64 Playwright workarounds needed.
    container = {
      enable = true;
      hostUsers = [ "ndufour" ];
      # Mount the host's NixOS CA bundle (which includes the Ptinem
      # private CA via mySystem.security.privateca) into the container
      # at a non-standard path so it doesn't clash with Ubuntu's
      # ca-certificates package (which tries to regenerate its own
      # bundle at /etc/ssl/certs/ca-certificates.crt and fails if that
      # path is a RO mount). SSL_CERT_FILE below points Python/openssl
      # at our mount.
      extraVolumes = [
        "/etc/ssl/certs/ca-bundle.crt:/etc/ssl/custom/ca-bundle.crt:ro"
      ];
      extraOptions = [
        "-e" "SSL_CERT_FILE=/etc/ssl/custom/ca-bundle.crt"
        "-e" "REQUESTS_CA_BUNDLE=/etc/ssl/custom/ca-bundle.crt"
      ];
    };

    settings.model = {
      default  = "google/gemma-4-31b-it";
      provider = "openrouter";
    };
  };

  sops.secrets."hermes-env" = {
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode  = "0400";
  };
}
