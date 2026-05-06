{
  config,
  pkgs,
  ...
}: {

  services.adguardhome = {
    enable = true;

    host = "127.0.0.1";
    port = 3003;

    settings = {
      http = {
        address = "127.0.0.1:3003";
      };
      dns = {
        # Bind on all interfaces; access is gated by the WAN port-53 drop in
        # firewall.nix and by the systemd RestrictNetworkInterfaces allowlist
        # below. Avoids coupling startup to specific IPs (notably the Tailscale
        # IP, which won't exist if tailscaled can't auth).
        bind_hosts = [ "0.0.0.0" ];
        upstream_dns = [
          "[/internal/]10.0.0.53"
          "127.0.0.1"
        ];
        blocking_mode = "nxdomain";
        ipv6 = false;
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;

        parental_enabled = false;  # Parental control-based DNS requests filtering.
        safe_search = {
          enabled = false;  # Enforcing "Safe search" option for search engines, when possible.
        };
      };
      # The following notation uses map
      # to not have to manually create {enabled = true; url = "";} for every filter
      # This is, however, fully optional
      # filters = map(url: { enabled = true; url = url; }) [
      #   "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt"  # The Big List of Hacked Malware Web Sites
      #   "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"  # malicious url blocklist
      # ];
    };
  };

  # Kernel-level allowlist of interfaces AdGuard may send/receive on.
  # Belt-and-suspenders to the WAN firewall: even if nftables is misconfigured,
  # wan0 traffic never reaches the AdGuard process. Name-based and resolved
  # lazily by BPF, so listing tailscale0 doesn't make startup depend on it.
  systemd.services.adguardhome.serviceConfig.RestrictNetworkInterfaces = [
    "lo"
    "lan0"
    "lab0"
    "lab1"
    "tailscale0"
  ];

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;

    virtualHosts."adguard.internal" = {
      serverName = "adguard.internal";
      extraConfig = ''
        client_max_body_size 2g;
      '';
      locations."/".proxyPass = "http://localhost:3003";
    };
  };

}