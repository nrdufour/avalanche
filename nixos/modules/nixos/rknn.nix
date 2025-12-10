{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.mySystem.rknn;
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
in

{
  options.mySystem.rknn = {
    enable = mkEnableOption "RKNN NPU support for Rockchip RK3588 and similar SoCs";

    enableRuntime = mkOption {
      type = types.bool;
      default = true;
      description = "Install RKNN runtime library (librknnrt.so)";
    };

    enableToolkitLite = mkOption {
      type = types.bool;
      default = true;
      description = "Install RKNN Toolkit Lite Python bindings for inference";
    };

    runtimePackage = mkOption {
      type = types.package;
      default = pkgs.rknn.runtime;
      description = "RKNN runtime package to use";
    };

    toolkitLitePackage = mkOption {
      type = types.package;
      default = pkgs.python312Packages.callPackage ../../pkgs/rknn/toolkit-lite.nix { rknn-runtime = cfg.runtimePackage; };
      description = "RKNN Toolkit Lite package to use";
    };

    loadKernelModule = mkOption {
      type = types.bool;
      default = true;
      description = "Attempt to load RKNPU kernel module on boot";
    };
  };

  config = mkIf (cfg.enable && isAarch64) {
    # Install runtime library and toolkit lite
    environment.systemPackages =
      (lib.optional cfg.enableRuntime cfg.runtimePackage) ++
      (lib.optional cfg.enableToolkitLite
        (pkgs.python312.withPackages (ps: [ cfg.toolkitLitePackage ])));

    # Set library path for runtime discovery
    environment.variables = mkIf cfg.enableRuntime {
      LD_LIBRARY_PATH = mkIf cfg.enableRuntime
        "$LD_LIBRARY_PATH:${cfg.runtimePackage}/lib";
    };

    # Load RKNPU kernel module if available
    boot.kernelModules = mkIf cfg.loadKernelModule [
      "rknpu"
    ];

    # Configure device permissions for NPU access
    services.udev.extraRules = mkIf cfg.enable ''
      # Rockchip RKNN NPU device access
      KERNEL=="rknpu", MODE="0666", GROUP="video"
      KERNEL=="rknpu_service", MODE="0666", GROUP="video"
    '';

    # Create symlinks for library discovery if needed
    system.activationScripts = mkIf cfg.enableRuntime {
      rknnLibraryLinks = stringAfter [ "etc" ] ''
        # Ensure librknnrt.so is accessible system-wide
        mkdir -p /usr/local/lib
        if [ ! -L /usr/local/lib/librknnrt.so ]; then
          ln -sfn ${cfg.runtimePackage}/lib/librknnrt.so /usr/local/lib/librknnrt.so || true
        fi
      '';
    };
  };

}
