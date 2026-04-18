{ pkgs, ... }: {
  # Ollama from unstable for the latest release. Muninn has no discrete
  # GPU (Beelink SER5 iGPU), so the plain CPU build is used.
  # Bound to loopback only; the hermes-agent container reaches it by
  # sharing the host network namespace (--network=host in hermes.nix).
  services.ollama = {
    enable = true;
    package = pkgs.unstable.ollama;

    host = "127.0.0.1";
    port = 11434;

    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };
}
