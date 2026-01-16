{ inputs, ... }:
{
  # NUR overlay
  nur = inputs.nur.overlays.default;

  # The unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

  # Custom forgejo-runner v12.1.2 overlay
  # Overrides the default forgejo-runner with v12.1.2 which includes critical bug fixes
  forgejo-runner-12 = final: prev: {
    forgejo-runner-12 = final.callPackage ../pkgs/forgejo-runner-12 { };
  };

  # Sentinel gateway management tool
  sentinel = final: prev: {
    sentinel = final.callPackage ../pkgs/sentinel { };
  };
}
