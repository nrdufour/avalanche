{
  pkgs,
  config,
  ...
}:
{
  config = {
    sops = {
      defaultSopsFile = ../../../secrets/routy/secrets.sops.yaml;
      secrets = {
        "update_tsig_key" = {
          mode = "0440";
          owner = "kea";
          group = "kea";
        };

        "tailscale_auth_key" = {
          mode = "0440";
          owner = "root";
          group = "root";
        };

        "sentinel_admin_password_hash" = {
          mode = "0400";
          owner = "sentinel";
          group = "sentinel";
        };

        "sentinel_session_secret" = {
          mode = "0400";
          owner = "sentinel";
          group = "sentinel";
        };
      };

      # nsupdate TSIG key template (different format than Knot's keyfile)
      templates."nsupdate_tsig_key" = {
        mode = "0440";
        owner = "root";
        group = "root";
        content = ''
          key "update" {
            algorithm hmac-sha256;
            secret "${config.sops.placeholder.update_tsig_key}";
          };
        '';
      };
    };
  };
}