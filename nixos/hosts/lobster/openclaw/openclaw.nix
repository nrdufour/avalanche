{ config, pkgs, lib, ... }:

let
  # Hardened OpenClaw configuration
  #
  # Security posture:
  #   - Gateway binds to 0.0.0.0 inside the container, but port mapping
  #     restricts host access to 127.0.0.1:18789 only
  #   - Token auth required (injected via OPENCLAW_GATEWAY_TOKEN env var)
  #   - Sandbox mode off because the container itself is the isolation boundary
  #     (read-only rootfs, cap-drop ALL, memory/pid limits)
  #   - Tool execution denied (messaging profile, no exec, workspace-only fs)
  #   - Plugin allowlist restricts to matrix, irc, anthropic, ollama, memory-core
  #   - Logging redacts sensitive tool output
  #
  # Secrets flow:
  #   sops secrets -> sops template (openclaw.env) -> podman --env-file
  #   Config references secrets via ${ENV_VAR} string interpolation
  #
  # Channel setup:
  #   Matrix is NOT pre-configured here. After deployment, run the setup
  #   wizard via the web UI or:
  #     podman exec -it openclaw openclaw channels setup matrix
  #
  openclawConfig = pkgs.writeText "openclaw.json" (builtins.toJSON {
    gateway = {
      mode = "local";
      bind = "lan"; # 0.0.0.0 inside container; host restricts via port mapping
      port = 18789;
      auth = {
        mode = "token";
        token = "\${OPENCLAW_GATEWAY_TOKEN}";
      };
    };

    agents = {
      defaults = {
        model = {
          primary = "anthropic/claude-sonnet-4-5";
        };
        sandbox = { mode = "off"; };
      };
      list = [
        {
          id = "floyd";
          name = "Floyd";
        }
      ];
    };

    tools = {
      profile = "messaging";
      fs = { workspaceOnly = true; };
      exec = {
        security = "deny";
        ask = "always";
      };
      elevated = { enabled = false; };
    };

    plugins = {
      enabled = true;
      allow = [
        "matrix"
        "irc"
        "anthropic"
        "ollama"
        "memory-core"
      ];
    };

    logging = {
      level = "info";
      redactSensitive = "tools";
    };
  });
in
{
  # --- Secrets ---

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

  # --- Initial config seeding ---
  # Copies the Nix-generated config on first boot.
  # After that, the config is writable (setup wizards, web UI edits).
  # To reset: delete /srv/openclaw/openclaw.json and restart.

  systemd.services.openclaw-init = {
    description = "Initialize OpenClaw configuration";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-openclaw.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f /srv/openclaw/openclaw.json ]; then
        cp ${openclawConfig} /srv/openclaw/openclaw.json
        chown 1000:1000 /srv/openclaw/openclaw.json
        chmod 600 /srv/openclaw/openclaw.json
      fi
    '';
  };

  # --- Container ---

  virtualisation.oci-containers.containers.openclaw = {
    image = "ghcr.io/openclaw/openclaw:2026.3.1";

    ports = [ "127.0.0.1:18789:18789" ];

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

      # DNS: use routy for .internal domain resolution
      "--dns=10.0.0.1"
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
