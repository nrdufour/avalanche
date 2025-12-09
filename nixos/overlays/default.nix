{ inputs, ... }:
let
  rknnOverlays = import ./rknn-packages.nix { inherit inputs; };
in
{
  # NUR overlay
  nur = inputs.nur.overlays.default;

  # The unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  };

  # RKNN packages overlay for RK3588 NPU support
  rknn-packages = rknnOverlays.rknn-packages;
}
