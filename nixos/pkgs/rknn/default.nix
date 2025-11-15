{ pkgs, lib }:

{
  # RKNN Runtime library (librknnrt.so + headers)
  runtime = pkgs.callPackage ./runtime.nix { };

  # RKNN Toolkit Lite - Python inference API
  toolkit-lite = pkgs.python312Packages.callPackage ./toolkit-lite.nix { };

  # Optional: RKNN Toolkit - full toolkit for model conversion
  # This would be for desktop/PC use, not needed on Orange Pi
  # toolkit = pkgs.callPackage ./toolkit.nix { };
}
