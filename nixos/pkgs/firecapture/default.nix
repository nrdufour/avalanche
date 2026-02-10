{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, dpkg
, zlib
, libusb1
, xorg
, udev
, alsa-lib
, freetype
, fontconfig
, jdk
, stdenv_cc ? stdenv.cc.cc.lib
}:

stdenv.mkDerivation rec {
  pname = "firecapture";
  version = "2.7.15";

  src = fetchurl {
    # GitHub mirror of the .deb (upstream requires captcha)
    url = "https://github.com/riblee/ppa/raw/3444cffcf5ceb18d47766e5108c91f66723dcf30/FireCapture_v${version}.deb";
    sha256 = "5b555735f85cb85da36bd29fb1a1690eae45f555cdb909d5e724f6402619ebba";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
  ];

  buildInputs = [
    zlib
    libusb1
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libXtst
    xorg.libXi
    udev
    alsa-lib
    freetype
    fontconfig
    stdenv_cc  # libstdc++.so.6, libgcc_s.so.1
  ];

  # avi_writer.so.1 is a bundled lib with a non-standard name that autoPatchelf can't resolve;
  # also ignore bundled JRE libs since we use system JDK instead
  autoPatchelfIgnoreMissingDeps = [ "avi_writer.so.1" ];

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/FireCapture
    cp -r opt/FireCapture_v2.7/* $out/opt/FireCapture/

    # Remove bundled JRE — we use the system JDK which has proper NixOS font config
    rm -rf $out/opt/FireCapture/jre

    # Launcher script: FireCapture expects a writable install directory for logs,
    # lock files, config, and script updates. We copy the nix store contents to
    # a mutable directory on first run (and on package updates).
    mkdir -p $out/bin
    classpath="$(find $out/opt/FireCapture/lib -name '*.jar' -printf '%p:')"
    cat > $out/bin/firecapture <<LAUNCHER
#!/bin/sh
FC_DIR="\$HOME/.local/share/FireCapture"
FC_STAMP="\$FC_DIR/.nix-store-path"

# Re-sync if first run or package changed
if [ ! -f "\$FC_STAMP" ] || [ "\$(cat "\$FC_STAMP")" != "$out" ]; then
  mkdir -p "\$FC_DIR"
  cp -r $out/opt/FireCapture/* "\$FC_DIR/"
  chmod -R u+w "\$FC_DIR"
  echo "$out" > "\$FC_STAMP"
fi

cd "\$FC_DIR"
export LD_LIBRARY_PATH="\$FC_DIR\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec ${jdk}/bin/java \\
  -Xms1024m -Xmx1024m -XX:+UseCompressedOops \\
  -classpath "$classpath" \\
  de.wonderplanets.firecapture.gui.FireCapture "\$@"
LAUNCHER
    chmod +x $out/bin/firecapture

    # Desktop entry
    mkdir -p $out/share/applications
    cat > $out/share/applications/firecapture.desktop <<EOF
[Desktop Entry]
Version=2.7
Name=FireCapture v2.7
Comment=FireCapture planetary capture tool
Exec=$out/bin/firecapture
Icon=$out/opt/FireCapture/icon.png
Terminal=false
Type=Application
Categories=Science;Astronomy;
EOF

    runHook postInstall
  '';

  meta = with lib; {
    description = "Planetary image capture software for astrophotography";
    homepage = "https://www.firecapture.de/";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "firecapture";
  };
}
