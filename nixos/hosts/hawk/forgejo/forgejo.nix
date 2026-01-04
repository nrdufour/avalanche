{
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.forgejo;
  srv = cfg.settings.server;
  forgejoPort = 4000;
in
{
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts.${cfg.settings.server.DOMAIN} = {
      forceSSL = true;
      enableACME = true;
      extraConfig = ''
        client_max_body_size 2g;
      '';
      locations."/" = {
        proxyPass = "http://localhost:${toString srv.HTTP_PORT}";
        extraConfig = ''
          # Increase timeouts for large git operations (e.g., nixpkgs full clone)
          # 10 minutes should cover most operations (full nixpkgs clone ~3-5min)
          proxy_read_timeout 600s;
          proxy_connect_timeout 75s;
          proxy_send_timeout 600s;
        '';
      };
    };
  };

  services.forgejo = {
    enable = true;
    stateDir = "/srv/forgejo";
    dump = {
      enable = true;
    };

    package = pkgs.unstable.forgejo;
    
    database = {
      type = "postgres";
      name = "forgejo";
      host = "localhost";
      user = "forgejo";
      passwordFile = config.sops.secrets.forgejo_db_password.path;
    };

    settings = {
      server = {
        DOMAIN = "forge.internal";
        # You need to specify this to remove the port from URLs in the web UI.
        ROOT_URL = "https://${srv.DOMAIN}/";
        HTTP_PORT = forgejoPort;
      };
      # You can temporarily allow registration to create an admin user.
      service.DISABLE_REGISTRATION = true;
      # Add support for actions, based on act: https://github.com/nektos/act
      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github";
      };
      # Increase git timeouts for large repository operations (e.g., nixpkgs mirror)
      "git.timeout" = {
        DEFAULT = 360;    # 6 minutes for normal ops
        MIGRATE = 3600;   # 1 hour for migrations
        MIRROR = 3600;    # 1 hour for mirror syncs
        CLONE = 3600;     # 1 hour for clones
        PULL = 3600;      # 1 hour for pulls
        GC = 600;         # 10 minutes for git gc
      };
      # Optimize git for x86_64 CPU (Ryzen 5 5500U, 6 cores)
      # Hawk has better CPU than ARM (eagle), enable compression for better disk efficiency
      git = {
        "gc.compression" = 1;       # Light compression during GC
        "pack.compression" = 1;     # Enable pack compression
        "pack.threads" = 6;         # Use all 6 cores for packing operations
        "pack.window" = 10;         # Default delta search window (balanced)
        "pack.depth" = 50;          # Default delta chain depth (balanced)
      };
      # Sending emails is completely optional
      # You can send a test email from the web UI at:
      # Profile Picture > Site Administration > Configuration >  Mailer Configuration 
      # mailer = {
      #   ENABLED = true;
      #   SMTP_ADDR = "mail.example.com";
      #   FROM = "noreply@${srv.DOMAIN}";
      #   USER = "noreply@${srv.DOMAIN}";
      # };
    };
    # mailerPasswordFile = config.age.secrets.forgejo-mailer-password.path;
  };

  # age.secrets.forgejo-mailer-password = {
  #   file = ../secrets/forgejo-mailer-password.age;
  #   mode = "400";
  #   owner = "forgejo";
  # };

  # Set global git config for forgejo user (persists across rebuilds)
  # These settings apply to git processes spawned by Forgejo (e.g., git-upload-pack for clones)
  systemd.services.forgejo.preStart = ''
    # Set pack.threads to use all 6 cores for pack operations (x86_64 optimization)
    ${pkgs.git}/bin/git config --global pack.threads 6
    ${pkgs.git}/bin/git config --global pack.compression 1
    ${pkgs.git}/bin/git config --global gc.compression 1
  '';

  security.acme.certs."forge.internal" = {};

  environment.systemPackages = with pkgs; [
    forgejo
  ];

}