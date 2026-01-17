{ lib
, config
, pkgs
, ...
}:
with lib;
let
  cfg = config.mySystem.services.sentinel;

  # Helper to get password hash - either from file or direct value
  getUserPasswordHash = user:
    if user.passwordHashFile != null
    then "$(cat ${user.passwordHashFile})"
    else user.passwordHash;

  # Session secret - either from file or direct value
  getSessionSecret =
    if cfg.session.secretFile != null
    then "$(cat ${cfg.session.secretFile})"
    else cfg.session.secret;

  # Check if any secrets come from files (requires runtime config generation)
  hasFileSecrets =
    cfg.session.secretFile != null ||
    (builtins.any (u: u.passwordHashFile != null) cfg.auth.local.users);

  # Generate static YAML configuration (used when no file secrets)
  staticConfigFile = pkgs.writeText "sentinel.yaml" (builtins.toJSON {
    server = {
      host = cfg.host;
      port = cfg.port;
      read_timeout = cfg.readTimeout;
      write_timeout = cfg.writeTimeout;
    };

    auth = {
      local = {
        enabled = cfg.auth.local.enable;
        users = map (u: {
          username = u.username;
          password_hash = u.passwordHash;
          role = u.role;
        }) cfg.auth.local.users;
      };
      oidc = {
        enabled = cfg.auth.oidc.enable;
        issuer = cfg.auth.oidc.issuer;
        client_id = cfg.auth.oidc.clientId;
        redirect_url = cfg.auth.oidc.redirectUrl;
      };
    };

    session = {
      secret = cfg.session.secret;
      lifetime = cfg.session.lifetime;
      secure = cfg.session.secure;
    };

    services = {
      systemd = map (s: {
        name = s.name;
        display_name = s.displayName;
        description = s.description;
        can_restart = s.canRestart;
      }) cfg.services.systemd;
      docker = {
        enabled = cfg.services.docker.enable;
        socket = cfg.services.docker.socket;
      };
    };

    collectors = {
      kea = {
        lease_file = cfg.collectors.kea.leaseFile;
        control_socket = cfg.collectors.kea.controlSocket;
      };
      adguard = {
        api_url = cfg.collectors.adguard.apiUrl;
        username = cfg.collectors.adguard.username;
      };
      network = {
        interfaces = map (i: {
          name = i.name;
          display_name = i.displayName;
          description = i.description;
        }) cfg.collectors.network.interfaces;
      };
      wan = {
        enabled = cfg.collectors.wan.enable;
        latency_targets = cfg.collectors.wan.latencyTargets;
        cache_duration = cfg.collectors.wan.cacheDuration;
      };
      tailscale = {
        enabled = cfg.collectors.tailscale.enable;
      };
      bandwidth = {
        enabled = cfg.collectors.bandwidth.enable;
        sample_rate = cfg.collectors.bandwidth.sampleRate;
        retention = cfg.collectors.bandwidth.retention;
      };
      lldp = {
        enabled = cfg.collectors.lldp.enable;
      };
      system = {
        disk_mount_points = cfg.collectors.system.diskMountPoints;
      };
    };

    logging = {
      level = cfg.logging.level;
      format = cfg.logging.format;
    };
  });

  # Script to generate config with secrets at runtime
  generateConfigScript = pkgs.writeShellScript "sentinel-generate-config" ''
    set -euo pipefail

    # Build users JSON array
    USERS_JSON='['
    ${concatMapStringsSep "\n    " (u: ''
      ${if u.passwordHashFile != null then ''
        PASSWORD_HASH="$(cat ${u.passwordHashFile})"
      '' else ''
        PASSWORD_HASH="${u.passwordHash}"
      ''}
      USERS_JSON="$USERS_JSON{\"username\":\"${u.username}\",\"password_hash\":\"$PASSWORD_HASH\",\"role\":\"${u.role}\"},"
    '') cfg.auth.local.users}
    USERS_JSON="''${USERS_JSON%,}]"

    # Get session secret
    ${if cfg.session.secretFile != null then ''
      SESSION_SECRET="$(cat ${cfg.session.secretFile})"
    '' else ''
      SESSION_SECRET="${cfg.session.secret}"
    ''}

    # Generate config file
    cat > /run/sentinel/config.yaml << EOF
    {
      "server": {
        "host": "${cfg.host}",
        "port": ${toString cfg.port},
        "read_timeout": "${cfg.readTimeout}",
        "write_timeout": "${cfg.writeTimeout}"
      },
      "auth": {
        "local": {
          "enabled": ${boolToString cfg.auth.local.enable},
          "users": $USERS_JSON
        },
        "oidc": {
          "enabled": ${boolToString cfg.auth.oidc.enable},
          "issuer": "${cfg.auth.oidc.issuer}",
          "client_id": "${cfg.auth.oidc.clientId}",
          "redirect_url": "${cfg.auth.oidc.redirectUrl}"
        }
      },
      "session": {
        "secret": "$SESSION_SECRET",
        "lifetime": "${cfg.session.lifetime}",
        "secure": ${boolToString cfg.session.secure}
      },
      "services": {
        "systemd": ${builtins.toJSON (map (s: {
          name = s.name;
          display_name = s.displayName;
          description = s.description;
          can_restart = s.canRestart;
        }) cfg.services.systemd)},
        "docker": {
          "enabled": ${boolToString cfg.services.docker.enable},
          "socket": "${cfg.services.docker.socket}"
        }
      },
      "collectors": {
        "kea": {
          "lease_file": "${cfg.collectors.kea.leaseFile}",
          "control_socket": "${cfg.collectors.kea.controlSocket}"
        },
        "adguard": {
          "api_url": "${cfg.collectors.adguard.apiUrl}",
          "username": "${cfg.collectors.adguard.username}"
        },
        "network": {
          "interfaces": ${builtins.toJSON (map (i: {
            name = i.name;
            display_name = i.displayName;
            description = i.description;
          }) cfg.collectors.network.interfaces)}
        },
        "wan": {
          "enabled": ${boolToString cfg.collectors.wan.enable},
          "latency_targets": ${builtins.toJSON cfg.collectors.wan.latencyTargets},
          "cache_duration": "${cfg.collectors.wan.cacheDuration}"
        },
        "tailscale": {
          "enabled": ${boolToString cfg.collectors.tailscale.enable}
        },
        "bandwidth": {
          "enabled": ${boolToString cfg.collectors.bandwidth.enable},
          "sample_rate": "${cfg.collectors.bandwidth.sampleRate}",
          "retention": "${cfg.collectors.bandwidth.retention}"
        },
        "lldp": {
          "enabled": ${boolToString cfg.collectors.lldp.enable}
        },
        "system": {
          "disk_mount_points": ${builtins.toJSON cfg.collectors.system.diskMountPoints}
        }
      },
      "logging": {
        "level": "${cfg.logging.level}",
        "format": "${cfg.logging.format}"
      }
    }
    EOF
    chmod 600 /run/sentinel/config.yaml
  '';

  # Choose config file based on whether we have file-based secrets
  configFile = if hasFileSecrets then "/run/sentinel/config.yaml" else staticConfigFile;

  # User type for authentication
  userType = types.submodule {
    options = {
      username = mkOption {
        type = types.str;
        description = "Username for authentication";
      };
      passwordHash = mkOption {
        type = types.str;
        default = "";
        description = "bcrypt hashed password (use passwordHashFile for secrets)";
      };
      passwordHashFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing bcrypt hashed password";
      };
      role = mkOption {
        type = types.enum [ "admin" "operator" "viewer" ];
        default = "viewer";
        description = "User role (admin, operator, viewer)";
      };
    };
  };

  # Service type for systemd services to monitor
  serviceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "systemd unit name";
      };
      displayName = mkOption {
        type = types.str;
        description = "Human-readable display name";
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "Service description";
      };
      canRestart = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the service can be restarted from the UI";
      };
    };
  };

  # Network interface type
  interfaceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Interface name (e.g., eth0, wan0)";
      };
      displayName = mkOption {
        type = types.str;
        description = "Human-readable display name";
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "Interface description";
      };
    };
  };
in
{
  options.mySystem.services.sentinel = {
    enable = mkEnableOption "Sentinel gateway management tool";

    package = mkPackageOption pkgs "sentinel" { };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port to listen on";
    };

    readTimeout = mkOption {
      type = types.str;
      default = "30s";
      description = "HTTP read timeout";
    };

    writeTimeout = mkOption {
      type = types.str;
      default = "30s";
      description = "HTTP write timeout";
    };

    # Authentication options
    auth = {
      local = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable local authentication";
        };
        users = mkOption {
          type = types.listOf userType;
          default = [ ];
          description = "List of local users";
        };
      };

      oidc = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable OIDC authentication";
        };
        issuer = mkOption {
          type = types.str;
          default = "";
          description = "OIDC issuer URL";
        };
        clientId = mkOption {
          type = types.str;
          default = "";
          description = "OIDC client ID";
        };
        redirectUrl = mkOption {
          type = types.str;
          default = "";
          description = "OIDC redirect URL";
        };
        clientSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to OIDC client secret file";
        };
      };
    };

    # Session options
    session = {
      secret = mkOption {
        type = types.str;
        default = "";
        description = "Session secret (should be set via secretsFile)";
      };
      secretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing session secret";
      };
      lifetime = mkOption {
        type = types.str;
        default = "24h";
        description = "Session lifetime";
      };
      secure = mkOption {
        type = types.bool;
        default = true;
        description = "Use secure cookies (requires HTTPS)";
      };
    };

    # Services to monitor
    services = {
      systemd = mkOption {
        type = types.listOf serviceType;
        default = [ ];
        description = "Systemd services to monitor";
      };
      docker = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Docker container monitoring";
        };
        socket = mkOption {
          type = types.str;
          default = "/var/run/docker.sock";
          description = "Docker socket path";
        };
      };
    };

    # Collectors
    collectors = {
      kea = {
        leaseFile = mkOption {
          type = types.str;
          default = "";
          description = "Path to Kea DHCP lease file";
        };
        controlSocket = mkOption {
          type = types.str;
          default = "";
          description = "Path to Kea control socket";
        };
      };

      adguard = {
        apiUrl = mkOption {
          type = types.str;
          default = "";
          description = "AdGuard Home API URL";
        };
        username = mkOption {
          type = types.str;
          default = "";
          description = "AdGuard Home username";
        };
      };

      network = {
        interfaces = mkOption {
          type = types.listOf interfaceType;
          default = [ ];
          description = "Network interfaces to monitor";
        };
      };

      wan = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable WAN status monitoring";
        };
        latencyTargets = mkOption {
          type = types.listOf types.str;
          default = [ "1.1.1.1" "8.8.8.8" ];
          description = "IP addresses to measure latency to";
        };
        cacheDuration = mkOption {
          type = types.str;
          default = "5m";
          description = "How long to cache WAN status results";
        };
      };

      tailscale = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Tailscale peer monitoring";
        };
      };

      bandwidth = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable bandwidth history tracking";
        };
        sampleRate = mkOption {
          type = types.str;
          default = "5s";
          description = "How often to sample bandwidth";
        };
        retention = mkOption {
          type = types.str;
          default = "1h";
          description = "How long to retain bandwidth history";
        };
      };

      lldp = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable LLDP neighbor discovery";
        };
      };

      system = {
        diskMountPoints = mkOption {
          type = types.listOf types.str;
          default = [ "/" ];
          description = "Disk mount points to monitor";
        };
      };
    };

    # Logging
    logging = {
      level = mkOption {
        type = types.enum [ "debug" "info" "warn" "error" ];
        default = "info";
        description = "Log level";
      };
      format = mkOption {
        type = types.enum [ "console" "json" ];
        default = "json";
        description = "Log format";
      };
    };

    # Nginx integration
    nginx = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable nginx reverse proxy";
      };
      hostname = mkOption {
        type = types.str;
        default = "sentinel.internal";
        description = "Hostname for nginx virtualhost";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure the package is available
    environment.systemPackages = [ cfg.package ];

    # Create sentinel user and group
    users.users.sentinel = {
      isSystemUser = true;
      group = "sentinel";
      description = "Sentinel gateway management service";
      extraGroups = [
        "systemd-journal"  # Read journald logs
      ] ++ optionals config.services.kea.dhcp4.enable [ "kea" ]
        ++ optionals cfg.collectors.lldp.enable [ "_lldpd" ];  # Access lldpd socket
    };
    users.groups.sentinel = { };

    # Watch for Kea control socket and trigger ACL setup when it appears
    systemd.paths.sentinel-kea-acl = mkIf (cfg.collectors.kea.controlSocket != "") {
      description = "Watch for Kea control socket";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = cfg.collectors.kea.controlSocket;
        Unit = "sentinel-kea-acl.service";
      };
    };

    # Grant sentinel access to Kea control socket via ACL
    systemd.services.sentinel-kea-acl = mkIf (cfg.collectors.kea.controlSocket != "") {
      description = "Set ACL for Sentinel to access Kea control socket";
      after = [ "kea-dhcp4-server.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          socketDir = builtins.dirOf cfg.collectors.kea.controlSocket;
          socketFile = cfg.collectors.kea.controlSocket;
        in pkgs.writeShellScript "sentinel-kea-acl" ''
          # /run/kea is a symlink to /run/private/kea (DynamicUser)
          # Grant traverse permission on /run/private for sentinel
          ${pkgs.acl}/bin/setfacl -m u:sentinel:x /run/private

          # Grant traverse permission on socket directory
          ${pkgs.acl}/bin/setfacl -m u:sentinel:rx ${socketDir}

          # Grant read/write access to the control socket
          ${pkgs.acl}/bin/setfacl -m u:sentinel:rw ${socketFile}
        '';
      };
    };

    # Systemd service
    systemd.services.sentinel = {
      description = "Sentinel Gateway Management";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Tools needed by sentinel
      path = with pkgs; [
        fping        # WAN latency measurements
        lldpd        # LLDP neighbor discovery (lldpctl)
        tailscale    # Tailscale peer status
      ];

      serviceConfig = {
        Type = "simple";
        User = "sentinel";
        Group = "sentinel";
        ExecStart = "${cfg.package}/bin/sentinel -config ${configFile}";
        Restart = "always";
        RestartSec = 5;

        # Runtime directory for config file with secrets
        RuntimeDirectory = "sentinel";
        RuntimeDirectoryMode = "0700";

        # Security hardening
        # NoNewPrivileges must be false to allow child processes (ping, traceroute, dig)
        # to inherit CAP_NET_RAW capability
        NoNewPrivileges = false;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;

        # Capabilities needed for network diagnostics and conntrack
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
      } // optionalAttrs hasFileSecrets {
        # Generate config with secrets before starting
        ExecStartPre = generateConfigScript;
      };
    };

    # Nginx reverse proxy
    services.nginx.virtualHosts = mkIf cfg.nginx.enable {
      "${cfg.nginx.hostname}" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://${cfg.host}:${toString cfg.port}";
          proxyWebsockets = true;
          # Note: Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto are set by
          # NixOS nginx recommendedProxySettings - don't duplicate them here
        };
        # SSE endpoint for firewall streaming
        locations."/api/firewall/stream" = {
          proxyPass = "http://${cfg.host}:${toString cfg.port}";
          extraConfig = ''
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 86400s;
            chunked_transfer_encoding off;
          '';
        };
      };
    };
  };
}
