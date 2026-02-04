# Declarative DNS Static Records for Knot DNS

**Status: COMPLETED** (February 2026)

**Implementation:**
- Module: `nixos/modules/nixos/services/dns-static-records.nix`
- Config: `nixos/hosts/routy/knot/static-records.nix`
- Guide: `docs/guides/dns-static-records.md`

---

## Problem Statement

Static DNS entries (NS records, infrastructure IPs) on routy are currently managed via manual `knotc zone-set` commands. This creates:
- No version-controlled source of truth
- No way to distinguish static entries from dynamic ones (DHCP/K8s)
- Risk of data loss if zone files are lost

## Current Architecture

### Knot DNS on routy

- **Zones**: `internal`, `10.in-addr.arpa`, `s3.garage.internal`
- **Zone files**: `/var/lib/knot/*.zone` (not version controlled)
- **TSIG key**: `update` (HMAC-SHA256) for authenticated RFC2136 updates
- **Config**: `nixos/hosts/routy/knot/dns.nix`

### Dynamic Update Sources (must coexist)

#### 1. Kea DHCP-DDNS
- **Source**: DHCP lease assignments
- **Zones updated**: `internal`, `10.in-addr.arpa`
- **Config**: `nixos/hosts/routy/kea/ddns.nix`
- **Ownership tracking**: None - raw A/PTR records without metadata
- **Example records**:
  ```
  laptop.internal.     300 A    10.0.0.42
  42.0.0.10.in-addr.arpa. 300 PTR laptop.internal.
  ```

#### 2. ExternalDNS (Kubernetes)
- **Source**: Kubernetes Ingresses and Services
- **Zone updated**: `internal`
- **Config**: `kubernetes/base/infra/network/external-dns/helm-values.yaml`
- **Ownership tracking**: TXT records with `k8s.` prefix
- **Settings**:
  ```yaml
  txtOwnerId: default
  txtPrefix: k8s.
  ```
- **Example records**:
  ```
  forge.internal.      300 A    10.1.0.5
  k8s.forge.internal.  300 TXT  "heritage=external-dns,external-dns/owner=default,external-dns/resource=ingress/forgejo/forge"
  ```

The TXT record allows ExternalDNS to:
- Know which records it owns (safe to modify/delete)
- Avoid touching records created by other systems
- Track which K8s resource created each record

## Solution: Nix Module + nsupdate + Ownership TXT Records

### Why This Approach

| Alternative | Verdict |
|-------------|---------|
| **OctoDNS** | Overkill - adds another tool for just static records |
| **dns.nix DSL** | Good typing but adds dependency; can adopt later |
| **Zone file approach** | Won't work - conflicts with DDNS updates |
| **Simple Nix + nsupdate** | ✅ Simple, native, follows existing patterns |

### Three-System Coexistence Model

After implementation, DNS records in the `internal` zone will have three distinct ownership patterns:

| Source | Owner TXT Pattern | Record Behavior |
|--------|-------------------|-----------------|
| **Nix (static)** | `nix.<name>.internal. TXT "heritage=nix,managed-by=routy"` | Managed by NixOS module |
| **DHCP (Kea)** | None | Created/removed with DHCP leases |
| **K8s (ExternalDNS)** | `k8s.<name>.internal. TXT "heritage=external-dns,..."` | Managed by ExternalDNS |

**Safety guarantees**:
- The Nix module ONLY touches records with `nix.*` TXT ownership markers
- ExternalDNS ONLY touches records with `k8s.*` TXT ownership markers
- DHCP records have no markers and are managed solely by Kea
- No system will interfere with another's records

### Example: Full Zone View

After all three systems are active:

```
; SOA and NS (Nix-managed)
internal.              300 SOA  ns0.internal. nemo.ptinem.casa. ...
internal.              300 NS   ns0.internal.
internal.              300 NS   ns1.internal.
nix-ns.internal.       300 TXT  "heritage=nix,type=NS,managed-by=routy"

; Infrastructure A records (Nix-managed)
ns0.internal.          300 A    10.0.0.53
nix.ns0.internal.      300 TXT  "heritage=nix,managed-by=routy"
ns1.internal.          300 A    10.1.0.53
nix.ns1.internal.      300 TXT  "heritage=nix,managed-by=routy"
routy.internal.        300 A    10.0.0.1
nix.routy.internal.    300 TXT  "heritage=nix,managed-by=routy"

; DHCP-assigned hosts (Kea-managed, no TXT)
laptop.internal.       300 A    10.0.0.42
printer.internal.      300 A    10.0.0.15

; Kubernetes services (ExternalDNS-managed)
forge.internal.        300 A    10.1.0.5
k8s.forge.internal.    300 TXT  "heritage=external-dns,external-dns/owner=default,..."
argocd.internal.       300 A    10.1.0.5
k8s.argocd.internal.   300 TXT  "heritage=external-dns,external-dns/owner=default,..."
```

## Module Design

### Location
`nixos/modules/nixos/services/dns-static-records.nix`

### Configuration Options

```nix
mySystem.services.dnsStaticRecords = {
  enable = true;
  dnsServer = "10.0.0.53";
  tsigKeyFile = config.sops.templates."nsupdate_tsig_key".path;
  ownerPrefix = "nix";  # TXT record prefix (default: "nix")
  managedBy = config.networking.hostName;  # Ownership identifier

  # New features
  dryRun = false;  # Set true to preview changes without applying
  metrics = {
    enable = true;
    path = "/var/lib/prometheus-node-exporter/dns_static_records.prom";
  };

  # Using dns.nix combinators for type-safe records
  zones = {
    "internal" = with dns.lib.combinators; {
      NS = [ "ns0.internal." "ns1.internal." "ns2.internal." ];
      subdomains = {
        ns0.A = [ "10.0.0.53" ];
        ns1.A = [ "10.1.0.53" ];
        ns2.A = [ "10.2.0.53" ];
        routy.A = [ "10.0.0.1" ];
        dns.CNAME = [ "ns0.internal." ];
      };
    };

    "10.in-addr.arpa" = with dns.lib.combinators; {
      NS = [ "ns0.internal." "ns1.internal." "ns2.internal." ];
      subdomains = {
        # PTR for 10.0.0.53
        "53.0.0".PTR = [ "ns0.internal." ];
        "53.0.1".PTR = [ "ns1.internal." ];
        "53.0.2".PTR = [ "ns2.internal." ];
      };
    };

    "s3.garage.internal" = with dns.lib.combinators; {
      NS = [ "ns0.internal." "ns1.internal." "ns2.internal." ];
    };
  };
};
```

### Record Type Support (via dns.nix)

dns.nix provides type-safe definitions for:
- `A` - IPv4 address records
- `AAAA` - IPv6 address records
- `CNAME` - Canonical name aliases
- `NS` - Nameserver records
- `PTR` - Reverse DNS pointers
- `TXT` - Text records
- `MX` - Mail exchange (if needed later)
- `SRV` - Service records (if needed later)
- `CAA` - Certificate authority authorization (if needed later)

### Sync Algorithm

The sync service runs as a systemd oneshot after `knot.service`:

1. **Query current state**: Use `dig AXFR` to get all `nix.*` TXT ownership records
2. **Parse desired state**: Read Nix-generated record list from `/run/dns-static/<zone>.desired`
3. **Compute diff**:
   - Records to add: in desired but missing from current
   - Records to delete: in current (with `nix.*` ownership) but not in desired
4. **Generate nsupdate batch**:
   ```
   server 10.0.0.53
   zone internal
   ; Deletions (only our records)
   update delete old-host.internal. A
   update delete nix.old-host.internal. TXT
   ; Additions
   update add ns0.internal. 300 A 10.0.0.53
   update add nix.ns0.internal. 300 TXT "heritage=nix,managed-by=routy"
   send
   ```
5. **Execute**: `nsupdate -k <tsig-key-file> <batch-file>`

### Conflict Detection

If a desired record name already exists WITHOUT a `nix.*` TXT marker:
- Log a warning (record owned by DHCP or ExternalDNS)
- Skip the record (do not overwrite)
- Optionally fail the service (configurable)

This prevents accidental overwrites of DHCP or K8s-managed records.

## Implementation Steps

### Step 0: Extract and review existing records (MUST DO FIRST)
**Location**: On routy via SSH

1. Run classification script (see Pre-Migration section)
2. Save output locally for review (temporary, not committed)
3. Create backup of zone files on routy
4. **MANUAL REVIEW CHECKPOINT**: User reviews extracted records and confirms:
   - All static records are identified
   - No records are missing
   - Classification is correct
5. Only proceed to Step 1 after user approval

### Step 1: Add dns.nix flake input
**File**: `flake.nix`

```nix
inputs.dns = {
  url = "github:nix-community/dns.nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### Step 2: Create the NixOS module
**File**: `nixos/modules/nixos/services/dns-static-records.nix`

- Use dns.nix types for record definitions
- Generate systemd oneshot service per zone
- Script logic: query owned records, diff, apply via nsupdate
- Handle "adopt" mode: add TXT ownership to existing matching records
- Implement dry-run mode (log changes, don't execute)
- Export Prometheus metrics to textfile collector

### Step 3: Add module import
**File**: `nixos/modules/nixos/services/default.nix`

Add import for the new module.

### Step 3: Create SOPS template for nsupdate
**File**: `nixos/hosts/routy/secrets.nix`

Add nsupdate-format TSIG key (different syntax than Knot's keyfile):
```
key "update" {
  algorithm hmac-sha256;
  secret "<secret>";
};
```

### Step 4: Configure routy with static records
**File**: `nixos/hosts/routy/knot/static-records.nix`

Define all static records for the three zones **using the records extracted in Step 0**.

### Step 5: Import in routy's default.nix
**File**: `nixos/hosts/routy/default.nix`

Add import for `./knot/static-records.nix`.

## Verification

### Pre-deployment (dry-run)
1. **Enable dry-run**: Set `dryRun = true` in config
2. **Build**: `nix build .#nixosConfigurations.routy.config.system.build.toplevel`
3. **Deploy**: `just nix deploy routy`
4. **Check logs**: `journalctl -u dns-static-sync-internal` shows planned changes
5. **Verify no changes made**: Zone unchanged

### Deployment
1. **Disable dry-run**: Set `dryRun = false`
2. **Deploy**: `just nix deploy routy`
3. **Check A record**: `dig @10.0.0.53 ns0.internal A`
4. **Check ownership TXT**: `dig @10.0.0.53 nix.ns0.internal TXT`
5. **Verify DHCP unaffected**: Check a known DHCP host still resolves
6. **Verify ExternalDNS unaffected**: Check `forge.internal` still resolves with `k8s.*` TXT

### Metrics
1. **Check metrics file**: `cat /var/lib/prometheus-node-exporter/dns_static_records.prom`
2. **Query Prometheus**: `dns_static_records_managed_count{zone="internal"}`
3. **Verify in Grafana**: Add panel for DNS sync status

### Record lifecycle
1. **Add record**: Add new entry to config, deploy, verify created
2. **Remove record**: Remove entry from config, deploy, verify deleted
3. **Modify record**: Change IP, deploy, verify updated

## Pre-Migration: Extract Existing Static Records

**CRITICAL**: Before implementing the new module, we must extract all existing static records from Knot to avoid data loss.

### Step 1: Dump Current Zone Contents

SSH to routy and dump all zones:

```bash
# On routy, dump each zone
knotc zone-read internal > /tmp/internal.zone.dump
knotc zone-read 10.in-addr.arpa > /tmp/reverse.zone.dump
knotc zone-read s3.garage.internal > /tmp/s3.zone.dump

# Or use AXFR from anywhere with TSIG key
dig @10.0.0.53 AXFR internal +nocomments > internal.zone.dump
dig @10.0.0.53 AXFR 10.in-addr.arpa +nocomments > reverse.zone.dump
dig @10.0.0.53 AXFR s3.garage.internal +nocomments > s3.zone.dump
```

### Step 2: Identify Record Sources

Use this classification to identify static vs dynamic records:

| Indicator | Source | Action |
|-----------|--------|--------|
| Has `k8s.<name>` TXT record | ExternalDNS (K8s) | Exclude - managed by K8s |
| Name matches DHCP reservation | Kea DHCP-DDNS | Exclude - managed by DHCP |
| Name matches known infra host | Static (manual) | **Include in Nix config** |
| SOA, NS records | Static (manual) | **Include in Nix config** |
| Unknown A record | Needs investigation | Check DHCP leases |

**DHCP-registered hosts** (from `nixos/hosts/routy/kea/dhcp.nix`):
- These names will appear in DNS via DHCP-DDNS
- Do NOT add them to the Nix static records

**ExternalDNS-managed records**:
- Look for corresponding `k8s.<name>.internal` TXT records
- These are managed by K8s Ingresses/Services

### Step 3: Generate Classification Script

Run this script on routy to classify records:

```bash
#!/usr/bin/env bash
# classify-dns-records.sh
# Run on routy to classify DNS records

ZONE="internal"
DNS_SERVER="10.0.0.53"

echo "=== Dumping zone $ZONE ==="
dig @$DNS_SERVER AXFR $ZONE +nocomments | grep -v "^;" | grep -v "^$" > /tmp/zone.dump

echo ""
echo "=== ExternalDNS-managed records (have k8s.* TXT) ==="
grep "^k8s\." /tmp/zone.dump | sed 's/^k8s\.//' | cut -d. -f1 | sort -u | while read name; do
  echo "  - $name (K8s-managed)"
done

echo ""
echo "=== Records to investigate ==="
# Get all A/CNAME records, exclude SOA/NS/TXT
grep -E "\s(A|CNAME)\s" /tmp/zone.dump | while read line; do
  name=$(echo "$line" | awk '{print $1}' | sed "s/\.${ZONE}\.$//" | sed 's/\.$//')
  type=$(echo "$line" | awk '{print $4}')
  value=$(echo "$line" | awk '{print $5}')

  # Check if K8s-managed
  if grep -q "^k8s\.${name}\.${ZONE}\." /tmp/zone.dump 2>/dev/null; then
    echo "  [K8S] $name $type $value"
  else
    echo "  [STATIC?] $name $type $value"
  fi
done

echo ""
echo "=== NS records (always static) ==="
grep -E "\sNS\s" /tmp/zone.dump

echo ""
echo "=== SOA record ==="
grep -E "\sSOA\s" /tmp/zone.dump
```

### Step 4: Manual Review and Nix Config Generation

After running the classification:

1. **Review `[STATIC?]` records** - determine if they're:
   - Infrastructure (ns0, ns1, routy, etc.) → Add to Nix config
   - DHCP clients without reservations → Leave alone (transient)
   - Unknown → Investigate before proceeding

2. **Generate initial Nix configuration** from confirmed static records:

```bash
# Example output format for Nix config
echo "Static records to add to Nix:"
echo "aRecords = ["
# ... generate from classified output
echo "];"
```

### Step 5: Backup Before Migration

Create a timestamped backup:

```bash
# On routy
BACKUP_DIR="/var/lib/knot/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /var/lib/knot/*.zone "$BACKUP_DIR/"
knotc zone-read internal > "$BACKUP_DIR/internal.full"
knotc zone-read 10.in-addr.arpa > "$BACKUP_DIR/reverse.full"
knotc zone-read s3.garage.internal > "$BACKUP_DIR/s3.full"
echo "Backup saved to $BACKUP_DIR"
```

## Migration Path

### Phase 1: Extract and Document (Pre-implementation)

1. Run classification script on routy
2. Document all static records discovered
3. Create the Nix configuration with discovered records
4. Verify the list is complete

### Phase 2: Deploy Module (Initial Sync)

1. Deploy the NixOS module to routy
2. Module will add ownership TXT markers to its records
3. Existing records remain untouched (no `nix.*` TXT = not managed)

### Phase 3: Adopt Existing Records

For records that already exist and should now be Nix-managed:

```bash
# The module handles this automatically on first run:
# - If record exists and matches desired state → add ownership TXT only
# - If record doesn't exist → create record + ownership TXT
# - If record exists but differs → log warning, skip (manual resolution needed)
```

### Phase 4: Verify and Clean Up

1. Verify all static records have `nix.*` TXT markers
2. Verify DHCP and K8s records are unaffected
3. Test adding/removing a record via Nix config

## Features (Initial Implementation)

### dns.nix DSL Integration

Use [dns.nix](https://github.com/nix-community/dns.nix) for strong typing and better ergonomics:

```nix
# Add to flake inputs
inputs.dns.url = "github:nix-community/dns.nix";

# In module
with dns.lib.combinators;
zones."internal" = {
  SOA = { ... };  # Auto-handled by Knot
  NS = [ "ns0.internal." "ns1.internal." ];
  subdomains = {
    ns0.A = [ "10.0.0.53" ];
    ns1.A = [ "10.1.0.53" ];
    routy.A = [ "10.0.0.1" ];
  };
};
```

**Benefits:**
- Type-safe record definitions (catches typos at eval time)
- Cleaner syntax with combinators
- Extensible for complex record types (SRV, CAA, etc.)

### Dry-Run Mode

Add `dryRun = true` option to preview changes without applying:

```nix
mySystem.services.dnsStaticRecords = {
  enable = true;
  dryRun = true;  # Log changes but don't apply
  # ...
};
```

**Use cases:**
- Review changes before deploying
- CI validation in `nix flake check`
- Debugging record sync issues

**Implementation:**
- Generate nsupdate commands but write to log instead of executing
- Exit with success/failure based on whether changes detected
- Could integrate with `just nix check` for pre-deploy validation

### Prometheus Metrics

Export sync status via node exporter textfile collector:

```
# /var/lib/prometheus-node-exporter/dns_static_records.prom
dns_static_records_last_sync_timestamp{zone="internal"} 1738678800
dns_static_records_sync_success{zone="internal"} 1
dns_static_records_managed_count{zone="internal"} 12
dns_static_records_errors_total{zone="internal"} 0
```

**Alerts:**
- Sync failures (service unit failed)
- Stale sync (last_sync > 24h)
- Record count drop (unexpected deletions)

## Future Enhancements

### Multi-Host Record Contributions

Allow hosts like mysecrets to declare their own DNS records:

```nix
# On mysecrets/default.nix
mySystem.dns.contribute = {
  enable = true;
  zone = "internal";
  records = {
    auth.A = [ "10.1.0.x" ];
    vault.A = [ "10.1.0.x" ];
  };
};
```

**Architecture:**
- Each host exports its desired records via a NixOS option
- A "collector" (routy) aggregates records from all hosts
- Collector pushes aggregated records to Knot

**Complexity:**
- Requires flake-level coordination between host configs
- Need to handle conflicts (two hosts claiming same name)
- Could use overlapping ownership prefixes (`nix-mysecrets.`, `nix-routy.`)

**Not implementing now** - current single-host approach is simpler and sufficient.

## Sources

- [dns.nix](https://github.com/nix-community/dns.nix) - Nix DSL for DNS zones
- [NixOS-DNS](https://github.com/Janik-Haag/NixOS-DNS) - Auto-generate DNS from NixOS modules
- [OctoDNS RFC2136](https://github.com/octodns/octodns-bind) - DNS as code with RFC2136
- [Knot DNS on NixOS](https://nohup.no/posts/knot-dns-on-nixos/) - Zone file pattern
- [Knot DNS Operation](https://www.knot-dns.cz/docs/3.4/html/operation.html) - knotc zone-set docs
- [ExternalDNS RFC2136](https://github.com/kubernetes-sigs/external-dns) - TXT ownership pattern
