{ inputs, ... }:
{
  # NUR overlay
  nur = inputs.nur.overlays.default;

  # The unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final) system;
      config.allowUnfree = true;
    };
  };

  # RKNN packages for NPU support on RK3588
  rknn-packages = final: _prev: {
    rknn = final.callPackage ../pkgs/rknn { };
  };
}
