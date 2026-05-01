{ ... }: {

  services.mattermost = {
    enable = true;
    siteUrl = "https://mattermost.internal";
    siteName = "Nemo Chat";
    preferNixConfig = true;
    mutableConfig = false;

    database = {
      create = true;
      peerAuth = true;
    };

    settings = {
      LogSettings.EnableDiagnostics = false;
      ServiceSettings.EnableSecurityAlertNotifications = false;
      ServiceSettings.EnableTutorial = false;
      TeamSettings.EnableTeamCreation = false;
      TeamSettings.EnableUserCreation = true;
    };
  };

  services.postgresql.enable = true;

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."mattermost.internal" = {
      forceSSL = true;
      enableACME = true;

      locations."/" = {
        proxyPass = "http://localhost:8065";
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 50m;
        '';
      };
    };
  };

  security.acme.certs."mattermost.internal" = { };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
