{
  pkgs,
  config,
  ...
}:
{
  config = {
    sops = {
      defaultSopsFile = ../../../secrets/hawk/secrets.sops.yaml;
    };
  };
}
