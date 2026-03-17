{ config, pkgs, lib, ... }:
{
  # Make kanidm tools available system-wide (same version as server)
  environment.systemPackages = [ pkgs.kanidm_1_8 ];

  # Kanidm secrets
  sops.secrets = {
    kanidm_admin_password = { };
  };

  # Kanidm identity management server
  services.kanidm = {
    enableServer = true;

    # Pin package version for stateVersion 23.11
    package = pkgs.kanidm_1_8;

    serverSettings = {
      # Domain for user identities (users will be user@auth.internal)
      domain = "auth.internal";

      # Origin - where to access the web UI
      origin = "https://auth.internal";

      # Bind on localhost only (accessed via nginx)
      bindaddress = "127.0.0.1:8300";

      # TLS certificates - generated via step-ca (stored in /var/lib/kanidm/certs)
      tls_chain = "/var/lib/kanidm/certs/cert.pem";
      tls_key = "/var/lib/kanidm/certs/key.pem";

      # Trust X-Forwarded-For from nginx
      trust_x_forward_for = true;

      # Enable online backups
      online_backup = {
        path = "/srv/backups/kanidm";
        schedule = "00 22 * * *";  # 22:00 UTC daily
        versions = 7;  # Keep 7 days of backups
      };

      # Logging
      log_level = "info";
    };
  };

  # Generate self-signed TLS certificate for Kanidm (localhost only)
  systemd.services.kanidm-cert = {
    description = "Generate self-signed TLS certificate for Kanidm";
    before = [ "kanidm.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      mkdir -p /var/lib/kanidm/certs
      cd /var/lib/kanidm/certs

      # Generate self-signed certificate if it doesn't exist
      if [ ! -f cert.pem ]; then
        echo "Generating self-signed certificate for Kanidm..."
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
          -nodes -keyout key.pem -out cert.pem -subj "/CN=localhost" \
          -addext "subjectAltName=DNS:localhost,DNS:auth.internal,IP:127.0.0.1"
        chown kanidm:kanidm cert.pem key.pem
        chmod 640 cert.pem key.pem
      fi
    '';
  };

  # Bind mount /var/lib/kanidm to USB drive
  fileSystems."/var/lib/kanidm" = {
    device = "/srv/kanidm";
    options = [ "bind" ];
  };

  # Ensure data directories exist on USB drive
  systemd.tmpfiles.rules = [
    "d /srv/kanidm 0700 kanidm kanidm -"
    "d /srv/backups/kanidm 0700 kanidm kanidm -"
  ];

  # Configure ACME to use step-ca instead of Let's Encrypt
  security.acme.certs."auth.internal" = {
    server = "https://mysecrets.internal:8443/acme/acme/directory";
    # Trust step-ca's root certificate
    extraLegoFlags = [
      "--http"
      "--http.webroot" "/var/lib/acme/acme-challenge"
      "--server" "https://mysecrets.internal:8443/acme/acme/directory"
    ];
  };

  # Trust step-ca root CA system-wide for ACME
  security.pki.certificateFiles = [ ../step-ca/resources/root_ca.crt ];

  # Nginx reverse proxy with ACME TLS (via step-ca)
  services.nginx.virtualHosts."auth.internal" = {
    enableACME = true;
    forceSSL = true;

    locations."/" = {
      # Kanidm requires TLS, so connect via HTTPS
      proxyPass = "https://127.0.0.1:8300";
      proxyWebsockets = true;
      extraConfig = ''
        # proxy_http_version already set by recommendedProxySettings
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;

        # Backend TLS settings
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name auth.internal;

        # Preserve cookies
        proxy_cookie_path / /;
        proxy_cookie_domain 127.0.0.1 $host;
      '';
    };
  };
}
