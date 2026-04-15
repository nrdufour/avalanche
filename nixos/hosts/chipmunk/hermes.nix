{ config, inputs, ... }: {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;

    # State lives on /srv (239GB USB stick) so the SD card doesn't take the
    # write load of a constantly-mutating agent. The upstream module mounts
    # stateDir into the container as /data when container mode is enabled.
    stateDir = "/srv/hermes";

    # Container mode gives Hermes a writable Ubuntu layer where it can
    # apt/pip/npm install arbitrary tools without polluting NixOS.
    # The docker backend auto-enables virtualisation.docker via mkDefault.
    container.enable = true;

    environmentFiles = [ config.sops.secrets."hermes-env".path ];

    settings.model = {
      default  = "anthropic/claude-opus-4.6";
      provider = "anthropic";
    };
  };

  sops.secrets."hermes-env" = {
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode  = "0400";
  };
}
