{
  pkgs,
  config,
  ...
}:
{
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "forgejo" "vaultwarden" ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  address          auth-method
      local all       postgres                 peer
      local all       all                      md5
      host  all       all     127.0.0.1/32     md5
      host  all       all     ::1/128          md5
    '';
    dataDir = "/srv/postgresql/${config.services.postgresql.package.psqlSchema}";
    initialScript = config.sops.templates."pg_init_script.sql".path;
  };

  services.postgresqlBackup = {
    enable = true;
    location = "/srv/backups/postgresql";
    databases = [ "vaultwarden" ];
  };

  sops.secrets = {
    forgejo_db_password = {
      owner = "forgejo";
    };
    vaultwarden_db_password = {};
  };

  sops.templates."pg_init_script.sql" = {
    owner = "postgres";
    content = ''
      CREATE ROLE forgejo WITH LOGIN PASSWORD '${config.sops.placeholder.forgejo_db_password}';
      GRANT ALL PRIVILEGES ON DATABASE forgejo TO forgejo;
      ALTER DATABASE forgejo OWNER TO forgejo;

      CREATE ROLE vaultwarden WITH LOGIN PASSWORD '${config.sops.placeholder.vaultwarden_db_password}';
      GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
      ALTER DATABASE vaultwarden OWNER TO vaultwarden;
    '';
  };
}
