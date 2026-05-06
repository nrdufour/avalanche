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
        bind_hosts = [
          "10.0.0.54"
          "10.1.0.54"
          "10.2.0.54"
          "100.121.204.6"  # Tailscale interface for remote DNS queries
        ];
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
      filters = map (url: { enabled = true; inherit url; }) [
        # Security
        "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt"   # The Big List of Hacked Malware Web Sites
        "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"  # Malicious URL Blocklist (URLHaus)
        "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt"  # Phishing URL Blocklist (PhishTank/OpenPhish)
        "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"  # uBlock₀ – Badware risks
        # Ads / trackers (mobile-leaning)
        "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt"   # AdAway Default Blocklist
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt"  # HaGeZi Pro
      ];
    };
  };

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