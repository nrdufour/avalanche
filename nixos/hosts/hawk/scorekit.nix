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

  sops.secrets.anthropic_api_key = {};

  sops.templates."scorekit.env" = {
    content = ''
      ANTHROPIC_API_KEY=${config.sops.placeholder.anthropic_api_key}
    '';
  };

  virtualisation.oci-containers.containers."scorekit" = {
    image = "forge.internal/nemo/scorekit:latest";
    extraOptions = [ "--pull=always" ];

    volumes = [
      "/srv/scorekit:/data"
    ];

    ports = [
      "127.0.0.1:8080:8080"
    ];

    environment = {
      TZ = "America/New_York";
    };

    environmentFiles = [
      config.sops.templates."scorekit.env".path
    ];
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
