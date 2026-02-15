{
  config,
  ...
}:
{
  # Hawk has Docker (for Forgejo runners), so use it as the OCI backend
  virtualisation.oci-containers.backend = "docker";

  # Ensure data directory exists
  systemd.tmpfiles.rules = [
    "d /srv/scorekit 0755 root root -"
  ];

  virtualisation.oci-containers.containers."scorekit" = {
    image = "forge.internal/nemo/scorekit:main-b632060-1771163874";

    volumes = [
      "/srv/scorekit:/data"
    ];

    ports = [
      "127.0.0.1:8080:8080"
    ];

    environment = {
      TZ = "America/New_York";
      # TODO: Add ANTHROPIC_API_KEY via SOPS secret for the Python instrument labeling pipeline
      # ANTHROPIC_API_KEY = "";
    };
  };

  # Nginx reverse proxy with ACME TLS
  services.nginx.virtualHosts."scorekit.internal" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true;
    };
  };

  security.acme.certs."scorekit.internal" = {};
}
