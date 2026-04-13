# Static DNS records for Knot DNS zones
#
# These records are managed declaratively via nsupdate with ownership TXT markers.
# Dynamic records from DHCP (Kea) and K8s (ExternalDNS) are NOT affected.
#
# Extracted from routy on 2026-02-04. Backup at docs/backups/2026-02-04-dns-zones-*.txt
{ config, ... }:

{
  mySystem.services.dnsStaticRecords = {
    enable = true;
    dryRun = false;  # Set to true to preview changes without applying
    dnsServer = "10.0.0.53";
    tsigKeyFile = config.sops.templates."nsupdate_tsig_key".path;

    zones = {
      # Main internal zone
      "internal" = {
        aRecords = [
          # Zone apex
          { name = "@"; ip = "10.0.0.1"; }
          # Nameservers
          { name = "ns0"; ip = "10.0.0.53"; }
          { name = "ns1"; ip = "10.1.0.53"; }
          # Gateway alias
          { name = "router"; ip = "10.0.0.1"; }
          # Bee cluster
          { name = "bee01"; ip = "10.2.0.10"; }
          { name = "bee02"; ip = "10.2.0.11"; }
          # Infrastructure hosts (static IPs, no longer DHCP-registered)
          { name = "opi01"; ip = "10.1.0.20"; }
          { name = "opi02"; ip = "10.1.0.21"; }
          { name = "opi03"; ip = "10.1.0.22"; }
          { name = "raccoon00"; ip = "10.1.0.30"; }
          { name = "raccoon01"; ip = "10.1.0.31"; }
          { name = "raccoon02"; ip = "10.1.0.32"; }
          { name = "raccoon03"; ip = "10.1.0.33"; }
          { name = "raccoon04"; ip = "10.1.0.34"; }
          { name = "raccoon05"; ip = "10.1.0.35"; }
          { name = "possum"; ip = "10.1.0.60"; }
          { name = "cardinal"; ip = "10.1.0.65"; }
          { name = "hawk"; ip = "10.1.0.91"; }
          { name = "lobster"; ip = "10.1.0.99"; }
        ];

        nsRecords = [
          { zone = "@"; nameserver = "ns0.internal."; }
          { zone = "@"; nameserver = "ns1.internal."; }
        ];

        cnameRecords = [
          # Gateway services
          { name = "adguard"; target = "router.internal."; }
          { name = "sentinel"; target = "router.internal."; }
          # Infrastructure services (hawk host)
          { name = "auth"; target = "hawk.internal."; }
          { name = "ca"; target = "hawk.internal."; }
          { name = "vaultwarden"; target = "hawk.internal."; }
          { name = "forge"; target = "hawk.internal."; }
          { name = "ntfy"; target = "hawk.internal."; }
          { name = "scorekit"; target = "bee01.internal."; }
          { name = "staging.scorekit"; target = "bee01.internal."; }
          # Metrics + logs (possum host)
          { name = "vm"; target = "possum.internal."; }
          { name = "vl"; target = "possum.internal."; }
          # Media services (cardinal host)
          { name = "jellyfin"; target = "cardinal.internal."; }
          { name = "jellyfin-tv"; target = "cardinal.internal."; }
          { name = "navidrome"; target = "cardinal.internal."; }
          { name = "cwa"; target = "cardinal.internal."; }
          # AI/ML (calypso workstation)
          { name = "ollama"; target = "calypso.internal."; }
          # Garage subdomains (cardinal host)
          { name = "ui.garage"; target = "cardinal.internal."; }
          { name = "web.garage"; target = "cardinal.internal."; }
        ];
      };

      # Reverse DNS zone for 10.x.x.x
      "10.in-addr.arpa" = {
        nsRecords = [
          { zone = "@"; nameserver = "ns0.internal."; }
          { zone = "@"; nameserver = "ns1.internal."; }
        ];
        ptrRecords = [
          # Infrastructure hosts (static IPs, no longer DHCP-registered)
          { ip = "10.1.0.20"; hostname = "opi01.internal."; }
          { ip = "10.1.0.21"; hostname = "opi02.internal."; }
          { ip = "10.1.0.22"; hostname = "opi03.internal."; }
          { ip = "10.1.0.30"; hostname = "raccoon00.internal."; }
          { ip = "10.1.0.31"; hostname = "raccoon01.internal."; }
          { ip = "10.1.0.32"; hostname = "raccoon02.internal."; }
          { ip = "10.1.0.33"; hostname = "raccoon03.internal."; }
          { ip = "10.1.0.34"; hostname = "raccoon04.internal."; }
          { ip = "10.1.0.35"; hostname = "raccoon05.internal."; }
          { ip = "10.1.0.60"; hostname = "possum.internal."; }
          { ip = "10.1.0.65"; hostname = "cardinal.internal."; }
          { ip = "10.1.0.91"; hostname = "hawk.internal."; }
          { ip = "10.1.0.99"; hostname = "lobster.internal."; }
        ];
      };

      # Garage S3 subdomain zone
      "s3.garage.internal" = {
        aRecords = [
          # Zone apex - points to cardinal (Garage server)
          { name = "@"; ip = "10.1.0.65"; }
          # Wildcard for all bucket subdomains
          { name = "*"; ip = "10.1.0.65"; }
        ];

        nsRecords = [
          { zone = "@"; nameserver = "ns0.internal."; }
          { zone = "@"; nameserver = "ns1.internal."; }
        ];
      };
    };
  };
}
