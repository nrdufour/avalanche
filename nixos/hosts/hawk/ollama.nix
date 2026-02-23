{ pkgs, ... }: {
  services.ollama = {
    enable = true;
    host = "0.0.0.0";
    port = 11434;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };

  networking.firewall.allowedTCPPorts = [ 11434 ];
}
