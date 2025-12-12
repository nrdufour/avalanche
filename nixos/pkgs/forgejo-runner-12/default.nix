{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

stdenv.mkDerivation rec {
  pname = "forgejo-runner";
  version = "12.1.2";

  src = fetchurl {
    url = "https://code.forgejo.org/forgejo/runner/releases/download/v${version}/forgejo-runner-${version}-linux-arm64";
    sha256 = "4295b9bc62ba12ae5fc94f1f58c78266628def57bdfdfef89e662cdcb2cf2211";
  };

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp $src $out/bin/forgejo-runner
    chmod +x $out/bin/forgejo-runner

    # Create act_runner symlink for backward compatibility with NixOS module
    ln -s $out/bin/forgejo-runner $out/bin/act_runner

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    $out/bin/forgejo-runner --version | grep -q "${version}"

    runHook postInstallCheck
  '';

  passthru.tests = {
    # Skip NixOS tests for now - can add later if needed
  };

  meta = with lib; {
    description = "Forgejo Actions runner (v12.1.2 - custom build for eagle.internal)";
    longDescription = ''
      Custom forgejo-runner v12.1.2 package for NixOS.
      This version includes critical bug fixes for:
      - Job finalization hanging
      - CPU spinning during action preparation
      - Docker >28.1 compatibility issues

      Built from official Forgejo release binary.
    '';
    homepage = "https://code.forgejo.org/forgejo/runner";
    changelog = "https://code.forgejo.org/forgejo/runner/releases/tag/v${version}";
    license = licenses.gpl3Plus;
    maintainers = [ ];
    mainProgram = "forgejo-runner";
    platforms = [ "aarch64-linux" ];
  };
}
