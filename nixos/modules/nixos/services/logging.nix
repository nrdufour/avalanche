{ lib, config, pkgs, ... }:

with lib;
let
  cfg = config.mySystem.services.logging;

  fluentBitConfig = {
    service = {
      flush = 5;
      log_level = "info";
    };

    pipeline = {
      inputs = [
        {
          name = "systemd";
          tag = "journal.*";
          systemd_filter_type = "and";
          read_from_tail = "on";
          strip_underscores = "on";
        }
      ];

      outputs = [
        {
          name = "http";
          match = "*";
          host = cfg.victorialogsHost;
          port = cfg.victorialogsPort;
          uri = "/insert/jsonline?_stream_fields=HOSTNAME,SYSTEMD_UNIT&_msg_field=MESSAGE&_time_field=TIMESTAMP";
          format = "json_lines";
          json_date_format = "iso8601";
          json_date_key = "TIMESTAMP";
        }
      ];
    };
  };
in
{
  options.mySystem.services.logging = {
    enable = mkEnableOption "Log shipping to VictoriaLogs via Fluent Bit";

    victorialogsHost = mkOption {
      type = types.str;
      default = "possum.internal";
      description = "Hostname or IP of the VictoriaLogs server.";
    };

    victorialogsPort = mkOption {
      type = types.port;
      default = 9428;
      description = "HTTP port of the VictoriaLogs server.";
    };
  };

  config = mkIf cfg.enable {
    services.fluent-bit = {
      enable = true;
      settings = fluentBitConfig;
    };
  };
}
