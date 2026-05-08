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

    # settings are deep-merged into config.yaml on every deploy via
    # configMergeScript (Nix keys win). No need to delete the file to pick
    # up changes.
    settings.model = {
      default  = "google/gemma-4-31b-it";
      provider = "openrouter";
    };

    # OpenRouter provider routing. `data_collection = "deny"` excludes any
    # upstream provider that retains prompt/response data (OpenRouter ZDR
    # filter). `require_parameters` drops providers that silently ignore
    # request params. `sort = "price"` picks the cheapest ZDR-compliant
    # provider that still honours the requested parameters.
    settings.provider_routing = {
      sort = "price";
      data_collection = "deny";
      require_parameters = true;
      ignore = [ "Venice" ];
    };

    # Calypso's local Ollama (NVIDIA GPU, gemma4:e4b). Available as an
    # additional provider to test local inference. Switch to it with:
    #   hermes model calypso-ollama/gemma4:e4b
    settings.providers."calypso-ollama" = {
      name    = "Calypso Ollama (gemma4:e4b)";
      base_url = "http://calypso.internal:11434/v1";
      model   = "gemma4:e4b";
      api_key = "ollama";
    };

    # SecondBrain knowledge base over MCP (HTTP transport).
    # API key lives in hermes-env (SOPS); hermes expands ${VAR} in headers.
    mcpServers.secondbrain = {
      url = "https://secondbrain.internal/mcp";
      headers."X-API-Key" = "\${SECONDBRAIN_API_KEY}";
    };
  };

  sops.secrets."hermes-env" = {
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode  = "0400";
  };
}
