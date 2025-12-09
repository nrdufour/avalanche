{ lib
, buildPythonPackage
, fetchurl
, rknn-runtime
, numpy
, opencv4
, pillow
, protobuf
, pyyaml
, tqdm
, scipy
}:

buildPythonPackage {
  pname = "rknn-toolkit-lite";
  version = "2.3.2";
  format = "wheel";

  src = fetchurl {
    url = "https://github.com/Pelochus/EZRKNN-Toolkit2/raw/main/rknn-toolkit-lite2/packages/rknn_toolkit_lite2-2.3.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl";
    sha256 = "e1e4ec691fed900c0e6fde5e7d8eeba17f806aa45092b63b361ee775e2c1b50e";
  };

  # Pre-built wheel - no build phase needed
  dontBuild = true;

  # Runtime dependencies
  dependencies = [
    numpy
    opencv4
    pillow
    protobuf
    pyyaml
    tqdm
    scipy
    rknn-runtime
  ];

  meta = with lib; {
    description = "Rockchip RKNN Toolkit Lite - Python API for NPU inference";
    homepage = "https://github.com/airockchip/rknn-toolkit2";
    license = licenses.unfree;
    platforms = ["aarch64-linux"];
    maintainers = with maintainers; [];
  };
}
