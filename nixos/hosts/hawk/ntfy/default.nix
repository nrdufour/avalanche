{ config, ... }:
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.internal";
      behind-proxy = true;
      # auth is intentionally left open — this instance only listens on
      # localhost and is reverse-proxied by nginx on the home network.
      # No external exposure.
    };
  };

  services.nginx.virtualHosts."ntfy.internal" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${config.services.ntfy-sh.settings.listen-http}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_redirect off;
        proxy_connect_timeout 3m;
        proxy_send_timeout 3m;
        proxy_read_timeout 3m;
        client_max_body_size 20M;
      '';
    };
  };
}
