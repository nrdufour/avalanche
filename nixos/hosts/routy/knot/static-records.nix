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
        ];

        nsRecords = [
          { zone = "@"; nameserver = "ns0.internal."; }
          { zone = "@"; nameserver = "ns1.internal."; }
        ];

        cnameRecords = [
          # Gateway services
          { name = "adguard"; target = "router.internal."; }
          { name = "sentinel"; target = "router.internal."; }
          # Identity & secrets (mysecrets host)
          { name = "auth"; target = "mysecrets.internal."; }
          { name = "vaultwarden"; target = "mysecrets.internal."; }
          # Forgejo (hawk host)
          { name = "forge"; target = "hawk.internal."; }
          # Metrics (possum host)
          { name = "vm"; target = "possum.internal."; }
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
      # Note: All PTR records are DHCP-managed via Kea DDNS
      "10.in-addr.arpa" = {
        nsRecords = [
          { zone = "@"; nameserver = "ns0.internal."; }
          { zone = "@"; nameserver = "ns1.internal."; }
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
