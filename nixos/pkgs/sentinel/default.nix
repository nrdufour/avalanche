{ lib
, buildGoModule
, templ
}:

buildGoModule rec {
  pname = "sentinel";
  version = "0.2.0";

  # Source from local src/sentinel directory
  # This path is relative to the flake root
  src = ../../../src/sentinel;

  vendorHash = null;

  # Build both the main sentinel binary and the hashpw helper
  subPackages = [
    "cmd/sentinel"
    "cmd/hashpw"
  ];

  nativeBuildInputs = [ templ ];

  preBuild = ''
    # Generate templ files
    templ generate
  '';

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
    "-X main.BuildTime=nixbuild"
  ];

  # Copy static files
  postInstall = ''
    mkdir -p $out/share/sentinel
    cp -r static $out/share/sentinel/
  '';

  meta = with lib; {
    description = "Gateway management and monitoring tool for NixOS routers";
    longDescription = ''
      Sentinel is a web-based gateway management tool that provides:
      - Service monitoring and control (systemd, Docker)
      - DHCP lease viewing (Kea integration)
      - Network diagnostics (ping, traceroute, DNS lookup)
      - Firewall log viewing (nftables)
      - Connection tracking (conntrack)
      - Prometheus metrics endpoint
    '';
    homepage = "https://forge.internal/nemo/avalanche";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "sentinel";
    platforms = platforms.linux;
  };
}
