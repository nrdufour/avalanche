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
