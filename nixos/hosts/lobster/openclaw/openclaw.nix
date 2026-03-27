{ config, pkgs, lib, ... }:

{
  # --- Secrets ---
  # Secrets are injected via env file; the config at
  # /srv/openclaw/config/openclaw.json references them via
  # ${ENV_VAR} string interpolation.

  sops.secrets = {
    openclaw_gateway_token = { };
    openclaw_anthropic_api_key = { };
    openclaw_matrix_access_token = { };
  };

  sops.templates."openclaw.env" = {
    content = ''
      OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.openclaw_gateway_token}
      ANTHROPIC_API_KEY=${config.sops.placeholder.openclaw_anthropic_api_key}
      MATRIX_ACCESS_TOKEN=${config.sops.placeholder.openclaw_matrix_access_token}
      OLLAMA_HOST=http://hawk.internal:11434
    '';
  };

  # --- Data directories ---

  systemd.tmpfiles.rules = [
    "d /srv/openclaw 0700 1000 1000 -"
    "d /srv/backups/openclaw 0700 1000 1000 -"
  ];

  # --- Container ---

  virtualisation.oci-containers.containers.openclaw = {
    image = "ghcr.io/openclaw/openclaw:2026.3.1";

    volumes = [
      "/srv/openclaw:/home/node/.openclaw"
    ];

    environment = {
      TZ = "America/New_York";
      NODE_ENV = "production";
    };

    environmentFiles = [
      config.sops.templates."openclaw.env".path
    ];

    extraOptions = [
      # Host networking: OpenClaw's "lan" bind mode resolves to 127.0.0.1,
      # which only works if the container shares the host network namespace.
      # The firewall restricts external access to ports 80/443 only.
      "--network=host"

      # Security hardening
      "--cap-drop=ALL"
      "--read-only"
      "--security-opt=no-new-privileges"

      # Resource limits (Pi 4 with 8GB - reserve headroom for host)
      "--memory=2g"
      "--memory-swap=3g"
      "--cpus=2"
      "--pids-limit=512"

      # Writable tmpfs for transient data
      "--tmpfs=/tmp:rw,noexec,nosuid,size=256m"
      "--tmpfs=/var/tmp:rw,noexec,nosuid,size=64m"
      "--tmpfs=/home/node/.npm:rw,size=128m"
    ];
  };

  # --- Nginx reverse proxy ---

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."openclaw.internal" = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:18789";
        proxyWebsockets = true;
        extraConfig = ''
          # Keep WebSocket connections alive for gateway protocol
          proxy_read_timeout 86400s;
          proxy_send_timeout 86400s;
        '';
      };
    };
  };
}
