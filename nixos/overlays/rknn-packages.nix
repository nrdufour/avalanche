{ inputs, ... }:

{
  # RKNN packages overlay
  rknn-packages = final: _prev: {
    rknn = final.callPackage ../pkgs/rknn { };
  };
}
