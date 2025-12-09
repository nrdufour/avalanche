{ lib
, stdenv
, fetchurl
}:

stdenv.mkDerivation {
  pname = "rknn-runtime";
  version = "2.3.2";

  src = fetchurl {
    url = "https://github.com/Pelochus/EZRKNN-Toolkit2/raw/main/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so";
    sha256 = "d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8";
  };

  # Fetch header files
  rknn_api_h = fetchurl {
    url = "https://raw.githubusercontent.com/Pelochus/EZRKNN-Toolkit2/main/rknpu2/runtime/Linux/librknn_api/include/rknn_api.h";
    sha256 = "c48e11a6f41b451a5fd1e4ad774ea60252d3d94f78bee9b21ea3d21b21deba9a";
  };

  rknn_custom_op_h = fetchurl {
    url = "https://raw.githubusercontent.com/Pelochus/EZRKNN-Toolkit2/main/rknpu2/runtime/Linux/librknn_api/include/rknn_custom_op.h";
    sha256 = "af5983da0ca244ca31dc3162aa683322b0285531196c7a770f29cd2e3b8ccaa6";
  };

  rknn_matmul_api_h = fetchurl {
    url = "https://raw.githubusercontent.com/Pelochus/EZRKNN-Toolkit2/main/rknpu2/runtime/Linux/librknn_api/include/rknn_matmul_api.h";
    sha256 = "aaadd9a7118de30a06b222996b6731db77095d00f5931a7a98c83a67f14a4d42";
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/lib $out/include

    # Install runtime library
    install -Dm755 $src $out/lib/librknnrt.so

    # Install header files
    install -Dm644 $rknn_api_h $out/include/rknn_api.h
    install -Dm644 $rknn_custom_op_h $out/include/rknn_custom_op.h
    install -Dm644 $rknn_matmul_api_h $out/include/rknn_matmul_api.h
  '';

  meta = with lib; {
    description = "Rockchip RKNN runtime library for NPU inference on RK3588 and similar SoCs";
    homepage = "https://github.com/airockchip/rknn-toolkit2";
    license = licenses.unfree;
    platforms = ["aarch64-linux"];
    maintainers = with maintainers; [];
  };
}
