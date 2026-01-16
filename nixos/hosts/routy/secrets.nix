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
    };
  };
}