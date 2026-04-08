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

  # SecondBrain thought capture service
  secondbrain = final: prev: {
    secondbrain = final.callPackage ../pkgs/secondbrain {
      secondbrain-src = inputs.secondbrain;
    };
  };

  # Sentinel gateway management tool
  sentinel = final: prev: {
    sentinel = final.callPackage ../pkgs/sentinel {
      sentinel-src = inputs.sentinel;
    };
  };

  # DRBD 9.3.1 — fixes kernel 6.18 compatibility (9.2.x broken on 6.16+)
  # Remove once nixpkgs#504903 merges
  drbd-9_3 = final: prev: let
    drbdOverride = lpFinal: lpPrev: {
      drbd = lpPrev.drbd.overrideAttrs (old: rec {
        version = "9.3.1";
        src = final.fetchurl {
          url = "https://pkg.linbit.com/downloads/drbd/9/drbd-${version}.tar.gz";
          hash = "sha256-g5BZRNHyeUIsaRTUcitQsfIm35IJ630K/otlZZNWEFo=";
        };
        meta = old.meta // { broken = false; };
      });
    };
  in {
    linuxPackages_6_18 = prev.linuxPackages_6_18.extend drbdOverride;
    linuxKernel = prev.linuxKernel // {
      packages = prev.linuxKernel.packages // {
        linux_6_18 = prev.linuxKernel.packages.linux_6_18.extend drbdOverride;
      };
    };
  };

  # FireCapture planetary imaging
  firecapture = final: prev: {
    firecapture = final.callPackage ../pkgs/firecapture { };
  };
}
