{ lib
, buildGoModule
, templ
, sentinel-src
}:

buildGoModule rec {
  pname = "sentinel";
  version = "0.2.2";

  # Source from flake input (updated via `nix flake update sentinel`)
  src = sentinel-src;

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

  # Static files are embedded in the binary, no postInstall needed

  meta = with lib; {
    description = "Gateway management and monitoring tool for NixOS routers";
    longDescription = ''
      Sentinel is a web-based gateway management tool that provides:
      - Service monitoring and control (systemd, Docker)
      - DHCP lease viewing (Kea integration)
      - Firewall log viewing (nftables)
      - Connection tracking (conntrack)
      - Network interface bandwidth monitoring
      - LLDP neighbor discovery
    '';
    homepage = "https://forge.internal/nemo/sentinel";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "sentinel";
    platforms = platforms.linux;
  };
}
