# Declarative DNS Static Records

Manage static DNS records on routy via Nix configuration with ownership tracking.

## Overview

Static records are managed in `nixos/hosts/routy/knot/static-records.nix` and synced via nsupdate. Each record gets an ownership TXT marker (`nix.*`) to distinguish from DHCP and Kubernetes records.

## Adding/Updating Records

Edit `nixos/hosts/routy/knot/static-records.nix`:

```nix
zones."internal" = {
  aRecords = [
    { name = "myhost"; ip = "10.0.0.50"; }
  ];
  cnameRecords = [
    { name = "alias"; target = "myhost.internal."; }
  ];
};
```

Deploy:
```bash
just nix deploy routy
```

## Removing Records

Delete the entry from config and deploy. The orphaned record and its ownership marker are automatically removed.

## Record Types

| Type | Syntax |
|------|--------|
| A | `{ name = "host"; ip = "10.0.0.1"; }` |
| CNAME | `{ name = "alias"; target = "host.internal."; }` |
| NS | `{ zone = "@"; nameserver = "ns0.internal."; }` |
| PTR | `{ ip = "10.0.0.1"; hostname = "host.internal."; }` |

Use `@` for zone apex, `*` for wildcards.

## Dry Run

Preview changes without applying:

```nix
mySystem.services.dnsStaticRecords = {
  dryRun = true;  # Set false to apply
  # ...
};
```

Check logs: `journalctl -u dns-static-records-internal`

## Verification

```bash
# Check record
dig @10.0.0.53 myhost.internal A

# Check ownership marker
dig @10.0.0.53 nix.myhost.internal TXT
```

## Coexistence

| Source | Ownership Pattern | Managed By |
|--------|-------------------|------------|
| Static (Nix) | `nix.*` TXT | This module |
| DHCP (Kea) | None | Kea DDNS |
| K8s (ExternalDNS) | `k8s.a-*` TXT | ExternalDNS |

The module only touches records with `nix.*` markers.

## Files

- **Module**: `nixos/modules/nixos/services/dns-static-records.nix`
- **Config**: `nixos/hosts/routy/knot/static-records.nix`
- **Metrics**: `/var/lib/prometheus-node-exporter-text-files/dns_static_records.*.prom`
