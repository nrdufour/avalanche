{
  pkgs,
  config,
  inputs,
  ...
}:
{
  # From https://wiki.nixos.org/wiki/Ollama
  # In NixOS 25.11, acceleration="cuda" automatically uses ollama-cuda package
  # Don't override with package= as it will ignore acceleration setting
  services.ollama = {
    enable = true;
    acceleration = "cuda";
  };

  # Ensure Ollama service has proper CUDA environment
  # This prevents CUDA initialization errors (999) after GPU-intensive workloads
  systemd.services.ollama = {
    path = [ config.boot.kernelPackages.nvidiaPackages.stable ];
    serviceConfig = {
      Environment = [
        "CUDA_PATH=${pkgs.cudaPackages.cudatoolkit}"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
        "OLLAMA_CONTEXT_LENGTH=32000"
        # Force GPU detection
        "CUDA_VISIBLE_DEVICES=0"
        "NVIDIA_VISIBLE_DEVICES=0"
      ];
    };
  };

  # Open Web UI at port 8080
  services.open-webui = {
    enable = true;
    environment = {
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
      OLLAMA_API_BASE_URL = "http://127.0.0.1:11434/api";
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
    };
  };

  # Nginx proxy for Ollama UI
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."ollama.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://localhost:8080";
        proxyWebsockets = true;
      };
      locations."/ws/" = {
        proxyPass = "http://localhost:8080/ws/";
        proxyWebsockets = true;
      };
    };
  };

  security.acme.certs."ollama.internal" = {};

  environment.systemPackages = with pkgs; [
    # Let's try this little guy as well ;)
    # vllm

    # Adding llama-cpp as is first to experiment
    llama-cpp

    # Claude-code became a must-have as well
    inputs.llm-agents.packages.${pkgs.system}.claude-code

    # Factory Droid - factory for creating AI agents
    inputs.llm-agents.packages.${pkgs.system}.droid

    # the contender ;) specially for ollama
    inputs.llm-agents.packages.${pkgs.system}.opencode

    # GPU reset helper script for when CUDA gets stuck after gaming
    (pkgs.writeShellScriptBin "reset-gpu" ''
      echo "=== GPU Reset for Ollama ==="
      echo ""
      echo "Checking for processes using NVIDIA GPU..."
      ${pkgs.lsof}/bin/lsof /dev/nvidia* 2>/dev/null | grep -v "gnome-shell" || echo "No non-GNOME processes found"

      # Kill any lingering Steam processes
      echo ""
      echo "Killing Steam processes..."
      ${pkgs.procps}/bin/pkill -f "steam" || echo "No Steam processes found"
      sleep 2

      # Try to unload just the UVM module (CUDA-specific)
      echo ""
      echo "Attempting to reset CUDA subsystem..."

      # Stop Ollama first
      systemctl stop ollama

      # Try to unload nvidia_uvm (CUDA-specific module)
      if modprobe -r nvidia_uvm 2>/dev/null; then
        echo "✓ Unloaded nvidia_uvm module"
        sleep 1
        modprobe nvidia_uvm
        echo "✓ Reloaded nvidia_uvm module"
      else
        echo "⚠ Could not reload nvidia_uvm (GNOME is using GPU)"
        echo "  Trying alternative: restart Ollama with fresh environment"
      fi

      # Restart Ollama (will pick up proper environment variables)
      echo ""
      echo "Restarting Ollama..."
      systemctl start ollama

      sleep 2
      echo ""
      echo "=== Status ==="
      systemctl status ollama --no-pager -l | head -20

      echo ""
      echo "If Ollama still can't see GPU, you may need to logout/login from GNOME"
      echo "or check logs with: journalctl -u ollama -n 50"
    '')

    # Check if Ollama is using GPU
    (pkgs.writeShellScriptBin "ollama-gpu-status" ''
      echo "=== Ollama GPU Status ==="
      echo ""

      # Check if Ollama is running
      if ! systemctl is-active --quiet ollama; then
        echo "❌ Ollama service is not running"
        exit 1
      fi

      echo "✓ Ollama service is running"
      echo ""

      # Check logs for GPU detection (from current boot, find most recent)
      echo "GPU Detection from logs:"
      GPU_INFO=$(journalctl -u ollama -b | grep "inference compute" | tail -1)

      if [ -z "$GPU_INFO" ]; then
        echo "⚠ No GPU detection logs found"
        echo "  Try restarting: sudo systemctl restart ollama"
      elif echo "$GPU_INFO" | grep -q "library=cuda"; then
        GPU_NAME=$(echo "$GPU_INFO" | grep -oP 'name="\K[^"]+' || echo "Unknown")
        GPU_VRAM=$(echo "$GPU_INFO" | grep -oP 'total="\K[^"]+' || echo "Unknown")
        echo "✓ Using CUDA GPU: $GPU_NAME"
        echo "  VRAM: $GPU_VRAM"
      elif echo "$GPU_INFO" | grep -q "library=cpu"; then
        echo "❌ Using CPU (GPU not detected)"
        echo "  Run 'sudo reset-gpu' to fix"
      fi

      echo ""
      echo "GPU Usage:"
      if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | \
          awk '{printf "  GPU Utilization: %s%%\n  VRAM Used: %s MB / %s MB\n", $1, $2, $3}' || echo "  Could not query GPU"
      else
        echo "  nvidia-smi not found in PATH"
      fi
    '')
  ];
}
