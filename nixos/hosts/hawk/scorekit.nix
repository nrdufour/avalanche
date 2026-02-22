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

  # Create a shared Docker network for inter-container communication
  systemd.services."docker-network-scorekit" = {
    serviceConfig.Type = "oneshot";
    wantedBy = [ "multi-user.target" ];
    before = [ "docker-scorekit.service" "docker-scorekit-worker.service" ];
    script = ''
      ${config.virtualisation.docker.package}/bin/docker network inspect scorekit >/dev/null 2>&1 || \
      ${config.virtualisation.docker.package}/bin/docker network create scorekit
    '';
  };

  virtualisation.oci-containers.containers."scorekit-worker" = {
    image = "forge.internal/nemo/scorekit-worker:latest";
    extraOptions = [ "--pull=always" "--network=scorekit" ];

    volumes = [
      "/srv/scorekit:/data"
    ];

    environment = {
      TZ = "America/New_York";
      WORKERS = "2";
      UNSCORE_LLM_LABELING = "false";
    };

    environmentFiles = [
      config.sops.templates."scorekit.env".path
    ];
  };

  virtualisation.oci-containers.containers."scorekit" = {
    image = "forge.internal/nemo/scorekit:latest";
    extraOptions = [ "--pull=always" "--network=scorekit" ];
    dependsOn = [ "scorekit-worker" ];

    volumes = [
      "/srv/scorekit:/data"
    ];

    ports = [
      "127.0.0.1:8080:8080"
    ];

    environment = {
      TZ = "America/New_York";
      SERVICE_URL = "http://scorekit-worker:8000";
      DISABLE_RATE_LIMIT = "true";
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
