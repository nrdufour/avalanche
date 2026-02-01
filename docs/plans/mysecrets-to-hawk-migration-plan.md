# Identity Infrastructure Migration: mysecrets → hawk

**Created:** 2026-02-01
**Status:** 📋 Planning
**Target Date:** TBD

## Progress Tracking

| Phase | Status | Date | Notes |
|-------|--------|------|-------|
| Feasibility analysis | ✅ Complete | 2026-02-01 | All services portable, YubiKey is critical blocker |
| Plan document | ✅ Complete | 2026-02-01 | This document |
| YubiKey relocation | ⏳ Pending | - | Physical hardware must be moved |
| Configuration preparation | ⏳ Pending | - | Copy/adapt NixOS configs |
| Secrets migration | ⏳ Pending | - | SOPS re-encryption |
| Data migration | ⏳ Pending | - | /srv contents transfer |
| Deployment | ⏳ Pending | - | nixos-rebuild on hawk |
| Validation | ⏳ Pending | - | Service testing |
| DNS cutover | ⏳ Pending | - | auth.internal → hawk |
| Decommission mysecrets | ⏳ Pending | - | After 30-day grace period |

---

## Executive Summary

This plan covers migrating the identity infrastructure stack from **mysecrets** (Raspberry Pi 4, aarch64) to **hawk** (Beelink SER5, x86_64).

### Services to Migrate

| Service | Purpose | Data | Complexity |
|---------|---------|------|------------|
| step-ca | Certificate Authority | Root/intermediate certs | **HIGH** (YubiKey) |
| Kanidm | Identity Management | SQLite database (~MB) | Medium |
| Vaultwarden | Password Manager | PostgreSQL database | Medium |
| PostgreSQL | Local database | Data directory | Medium |

### Critical Constraint: YubiKey Hardware Token

**The step-ca intermediate CA private key is stored on a physical YubiKey** configured at `yubikey:slot-id=9c`. This hardware token MUST be physically relocated to hawk before step-ca can function.

---

## Migration Strategy Decision

### Option A: All-at-Once Migration (Recommended)

**Migrate all services in a single maintenance window.**

| Aspect | Assessment |
|--------|------------|
| Downtime | Single window: 2-4 hours |
| Complexity | Moderate - all services move together |
| Rollback | Simple - revert everything to mysecrets |
| YubiKey | Move once, stays with step-ca on hawk |

**Pros:**
- Services remain co-located (step-ca issues certs for Kanidm/Vaultwarden)
- Single maintenance window, less user disruption
- Simpler rollback (all or nothing)
- No split-brain DNS/routing complexity

**Cons:**
- Larger blast radius if something fails
- Longer single downtime window

### Option B: Service-by-Service Migration

**Migrate services incrementally over multiple windows.**

| Order | Service | Dependency Constraint |
|-------|---------|----------------------|
| 1 | step-ca | Must migrate first (issues ACME certs) |
| 2 | Kanidm | Needs step-ca for TLS cert renewal |
| 3 | Vaultwarden + PostgreSQL | Needs step-ca for TLS cert renewal |

**Pros:**
- Smaller blast radius per migration
- Easier to debug issues
- Shorter individual downtimes

**Cons:**
- Multiple maintenance windows
- step-ca MUST move first (blocking dependency)
- Services temporarily split across hosts
- More complex DNS/routing during transition
- YubiKey still only moves once (to step-ca's host)

### Recommendation: Option A (All-at-Once)

**Rationale:**
1. **Tight coupling**: All services depend on step-ca for ACME certificates
2. **YubiKey singleton**: Hardware token can only be in one place
3. **Precedent**: Forgejo migration (similar scope) completed successfully in ~75 minutes
4. **Rollback simplicity**: Keep mysecrets intact until validation complete

---

## Architecture Comparison

| Aspect | mysecrets (Source) | hawk (Destination) |
|--------|-------------------|-------------------|
| Architecture | aarch64-linux (ARM) | x86_64-linux (AMD) |
| Hardware | Raspberry Pi 4, 4GB RAM | Beelink SER5 Max, 24GB RAM |
| Storage | SD card + USB drive (/srv) | NVMe + ext4 (/srv mount exists) |
| State Version | 23.11 | 25.11 |
| Current Services | step-ca, Kanidm, Vaultwarden | Forgejo, PostgreSQL |
| Network | Tailscale client | Tailscale client (to configure) |

### Package Compatibility

All services have x86_64 packages available:
- ✅ step-ca (pure Go)
- ✅ Kanidm (Rust, both archs supported)
- ✅ Vaultwarden (Rust, both archs supported)
- ✅ PostgreSQL (universal)

---

## Pre-Migration Checklist

### Hardware Requirements

- [ ] **YubiKey physically available** and relocatable to hawk
- [ ] **USB port on hawk** accessible for YubiKey
- [ ] **hawk /srv mount** verified with sufficient space (~5GB needed)

### Configuration Preparation

- [ ] Create `nixos/hosts/hawk/step-ca/` directory
- [ ] Create `nixos/hosts/hawk/kanidm/` directory
- [ ] Create `nixos/hosts/hawk/vaultwarden/` directory
- [ ] Copy and adapt configurations from mysecrets
- [ ] Update state version handling (23.11 → 25.11 considerations)

### Secrets Migration

- [ ] Add identity service secrets to `secrets/hawk/secrets.sops.yaml`:
  - `stepca_intermediate_password`
  - `stepca_yubikey_pin`
  - `kanidm_admin_password`
  - `vaultwarden_db_password`
  - `vaultwarden_admin_token`
  - `vaultwarden_smtp_password`
- [ ] Update `.sops.yaml` creation rules if needed
- [ ] Run `just sops update` to re-encrypt

### Build Validation

- [ ] `nix flake check` passes
- [ ] `nix build .#nixosConfigurations.hawk.config.system.build.toplevel` succeeds
- [ ] No architecture-specific errors

---

## Phase 1: Configuration Preparation

### Step 1.1: Create Directory Structure

```bash
cd /home/ndufour/Documents/code/projects/avalanche

# Create service directories
mkdir -p nixos/hosts/hawk/step-ca
mkdir -p nixos/hosts/hawk/kanidm
mkdir -p nixos/hosts/hawk/vaultwarden
```

### Step 1.2: Copy step-ca Configuration

```bash
# Copy step-ca config
cp nixos/hosts/mysecrets/step-ca/default.nix nixos/hosts/hawk/step-ca/
cp -r nixos/hosts/mysecrets/step-ca/resources nixos/hosts/hawk/step-ca/
```

**Modifications required:**
- None expected - configuration is architecture-agnostic
- YubiKey path remains `yubikey:slot-id=9c`

### Step 1.3: Copy Kanidm Configuration

```bash
cp nixos/hosts/mysecrets/kanidm/default.nix nixos/hosts/hawk/kanidm/
```

**Modifications required:**
- Review state version implications (23.11 → 25.11)
- Kanidm database may need schema migration
- Test upgrade path: 1.8 → current version

### Step 1.4: Copy Vaultwarden Configuration

```bash
cp nixos/hosts/mysecrets/vaultwarden/default.nix nixos/hosts/hawk/vaultwarden/
cp nixos/hosts/mysecrets/vaultwarden/local-pg.nix nixos/hosts/hawk/vaultwarden/
cp nixos/hosts/mysecrets/vaultwarden/vaultwarden.nix nixos/hosts/hawk/vaultwarden/
```

**Modifications required:**
- PostgreSQL data directory path verification
- ACME domain configuration (same: vaultwarden.internal)

### Step 1.5: Update hawk/default.nix

Add imports for new services:

```nix
imports = [
  ./hardware-configuration.nix
  ./secrets.nix
  ./forgejo        # existing
  ./step-ca        # ADD
  ./kanidm         # ADD
  ./vaultwarden    # ADD
];
```

### Step 1.6: Migrate Secrets

```bash
# Decrypt mysecrets secrets
sops -d secrets/mysecrets/secrets.sops.yaml > /tmp/mysecrets-plain.yaml

# Edit hawk secrets to add identity service secrets
sops secrets/hawk/secrets.sops.yaml

# Add:
# stepca_intermediate_password: <value>
# stepca_yubikey_pin: <value>
# kanidm_admin_password: <value>
# vaultwarden_db_password: <value>
# vaultwarden_admin_token: <value>
# vaultwarden_smtp_password: <value>

# Secure cleanup
shred -u /tmp/mysecrets-plain.yaml
```

### Step 1.7: Build Validation

```bash
# Check flake
nix flake check

# Build hawk (don't deploy yet)
nix build .#nixosConfigurations.hawk.config.system.build.toplevel

# Verify success
echo $?  # Should be 0
```

---

## Phase 2: Data Migration Preparation

### Step 2.1: Backup mysecrets Data

```bash
ssh mysecrets.internal

# Trigger fresh backups
sudo systemctl start kanidm-backup.service
sudo systemctl start postgresql-backup.service

# Verify backups
ls -lh /srv/backups/kanidm/
ls -lh /srv/backups/postgresql/

# Create migration snapshot
DATE=$(date +%Y%m%d)
sudo tar -czvf /srv/mysecrets-migration-backup-$DATE.tar.gz \
  /srv/kanidm \
  /srv/postgresql \
  /srv/backups
```

### Step 2.2: Document Current State

```bash
ssh mysecrets.internal

# Database record counts (for validation)
sudo -u postgres psql vaultwarden -c "SELECT COUNT(*) FROM users;"
# Record: ___ users

# Kanidm state
sudo kanidm system state --name admin
# Record any important metrics
```

---

## Phase 3: Migration Execution (Maintenance Window)

**Estimated duration:** 2-4 hours
**Prerequisites:** Phase 1 and 2 completed

### Step 3.1: Announce Maintenance

Notify users of:
- Certificate Authority (step-ca) downtime
- Identity provider (Kanidm) downtime
- Password manager (Vaultwarden) downtime
- Expected duration: 2-4 hours

### Step 3.2: Stop mysecrets Services

```bash
ssh mysecrets.internal

# Stop services in reverse dependency order
sudo systemctl stop nginx.service
sudo systemctl stop vaultwarden.service
sudo systemctl stop kanidm.service
sudo systemctl stop step-ca.service

# Keep PostgreSQL running for dump
sudo systemctl status postgresql.service

# Verify stopped
systemctl status step-ca kanidm vaultwarden nginx
```

### Step 3.3: Export PostgreSQL Database

```bash
ssh mysecrets.internal

# Create PostgreSQL dump
sudo -u postgres pg_dump vaultwarden | gzip > /tmp/vaultwarden-db-migration.sql.gz

# Verify dump
ls -lh /tmp/vaultwarden-db-migration.sql.gz
gunzip -c /tmp/vaultwarden-db-migration.sql.gz | head -50
```

### Step 3.4: Transfer Data to hawk

```bash
# From workstation (intermediary transfer like Forgejo migration)

# Create staging directory on hawk
ssh hawk.internal "sudo mkdir -p /srv/kanidm /srv/postgresql /srv/backups"

# Option A: Direct rsync (if SSH works)
ssh mysecrets.internal "sudo rsync -avz /srv/kanidm/ hawk.internal:/srv/kanidm/"
ssh mysecrets.internal "sudo rsync -avz /srv/postgresql/ hawk.internal:/srv/postgresql/"

# Option B: Tarball via workstation (if direct SSH is problematic)
ssh mysecrets.internal "sudo tar -cf - /srv/kanidm /srv/postgresql" | \
  ssh hawk.internal "sudo tar -xf - -C /"

# Transfer database dump
scp mysecrets.internal:/tmp/vaultwarden-db-migration.sql.gz hawk.internal:/tmp/
```

### Step 3.5: Relocate YubiKey

**Physical action required:**

1. Unplug YubiKey from mysecrets
2. Plug YubiKey into hawk USB port
3. Verify detection on hawk:

```bash
ssh hawk.internal
lsusb | grep -i yubi
# Should show: Yubico YubiKey ...

# Test YubiKey access
ykman info
# Should show device info
```

### Step 3.6: Deploy Configuration to hawk

```bash
cd /home/ndufour/Documents/code/projects/avalanche

# Commit configuration
git add nixos/hosts/hawk/
git add secrets/hawk/
git commit -m "feat(hawk): add identity infrastructure from mysecrets

Migrate step-ca, Kanidm, and Vaultwarden from mysecrets (aarch64)
to hawk (x86_64).

Services:
- step-ca: Certificate Authority with YubiKey HSM
- Kanidm: Identity Management (OIDC/OAuth2)
- Vaultwarden: Password Manager

Requires physical YubiKey relocation to hawk."

git push

# Deploy
just nix deploy hawk

# Monitor deployment
ssh hawk.internal "journalctl -f"
```

### Step 3.7: Import PostgreSQL Database

```bash
ssh hawk.internal

# Stop Vaultwarden (if started)
sudo systemctl stop vaultwarden.service

# Create database
sudo -u postgres createdb vaultwarden

# Import dump
gunzip -c /tmp/vaultwarden-db-migration.sql.gz | sudo -u postgres psql vaultwarden

# Set password from secrets
sudo -u postgres psql vaultwarden -c \
  "ALTER ROLE vaultwarden WITH PASSWORD '$(sudo cat /run/secrets/vaultwarden_db_password)';"

# Verify import
sudo -u postgres psql vaultwarden -c "SELECT COUNT(*) FROM users;"
# Should match pre-migration count
```

### Step 3.8: Fix File Ownership

```bash
ssh hawk.internal

# Kanidm
sudo chown -R kanidm:kanidm /srv/kanidm

# PostgreSQL
sudo chown -R postgres:postgres /srv/postgresql

# Verify permissions
ls -la /srv/kanidm/
ls -la /srv/postgresql/
```

### Step 3.9: Start Services on hawk

```bash
ssh hawk.internal

# Start services in dependency order
sudo systemctl start step-ca.service
sleep 5
sudo systemctl status step-ca.service

sudo systemctl start kanidm.service
sleep 5
sudo systemctl status kanidm.service

sudo systemctl start vaultwarden.service
sleep 5
sudo systemctl status vaultwarden.service

# Start nginx for reverse proxy
sudo systemctl start nginx.service
sudo systemctl status nginx.service
```

### Step 3.10: DNS Cutover

```bash
ssh routy.internal

# Update DNS records
sudo knotc zone-begin internal

# Update auth.internal CNAME
sudo knotc zone-unset internal auth CNAME
sudo knotc zone-set internal auth 300 CNAME hawk

# Update vaultwarden.internal CNAME (if exists)
sudo knotc zone-unset internal vaultwarden CNAME
sudo knotc zone-set internal vaultwarden 300 CNAME hawk

sudo knotc zone-commit internal

# Verify
dig @localhost auth.internal +short
# Expected: hawk.internal. then 10.1.0.91
```

---

## Phase 4: Validation

### Step 4.1: Service Health Checks

```bash
ssh hawk.internal

# Check all services running
systemctl status step-ca kanidm vaultwarden postgresql nginx

# Check for errors
journalctl -u step-ca --since "30 minutes ago" | grep -i error
journalctl -u kanidm --since "30 minutes ago" | grep -i error
journalctl -u vaultwarden --since "30 minutes ago" | grep -i error
```

### Step 4.2: step-ca Validation

```bash
# Test certificate issuance
step ca certificate test.internal test.crt test.key \
  --ca-url https://auth.internal:8443 \
  --provisioner acme

# Verify cert issued
openssl x509 -in test.crt -text -noout | head -20

# Cleanup
rm test.crt test.key
```

### Step 4.3: Kanidm Validation

```bash
# Test login
kanidm login --name admin

# Verify user lookup
kanidm person list --name admin

# Test OIDC endpoint
curl -I https://auth.internal/.well-known/openid-configuration
# Expected: HTTP/1.1 200 OK
```

### Step 4.4: Vaultwarden Validation

```bash
# Test web access
curl -I https://vaultwarden.internal/
# Expected: HTTP/1.1 200 OK

# Test API
curl https://vaultwarden.internal/api/config
# Expected: JSON config response
```

### Step 4.5: ACME Certificate Renewal Test

```bash
ssh hawk.internal

# Force ACME renewal for Kanidm
sudo systemctl restart acme-auth.internal.service
sudo systemctl status acme-auth.internal.service

# Force ACME renewal for Vaultwarden
sudo systemctl restart acme-vaultwarden.internal.service
sudo systemctl status acme-vaultwarden.internal.service

# Verify certs from step-ca (not self-signed)
echo | openssl s_client -connect auth.internal:443 2>/dev/null | \
  openssl x509 -noout -issuer
# Expected: issuer containing "Ptinem" or your CA name
```

### Validation Checklist

- [ ] step-ca service running
- [ ] step-ca can issue certificates
- [ ] YubiKey accessible (`ykman info` works)
- [ ] Kanidm service running
- [ ] Kanidm admin login works
- [ ] Kanidm OIDC endpoint accessible
- [ ] Vaultwarden service running
- [ ] Vaultwarden web UI accessible
- [ ] PostgreSQL database queries succeed
- [ ] ACME certificates from step-ca (not self-signed)
- [ ] DNS resolves auth.internal → hawk
- [ ] No critical errors in service logs

---

## Phase 5: Post-Migration

### Step 5.1: Monitoring Period (Days 1-7)

**Daily checks:**

```bash
# Service status
ssh hawk.internal "systemctl status step-ca kanidm vaultwarden"

# Error check
ssh hawk.internal "journalctl --since yesterday -p err"

# Disk usage
ssh hawk.internal "df -h /srv"

# Backup status
ssh hawk.internal "systemctl status kanidm-backup postgresql-backup"
```

### Step 5.2: Disable mysecrets Auto-Upgrade (Day 7)

```bash
# Edit mysecrets config
# nixos/hosts/mysecrets/default.nix

# Set:
# system.autoUpgrade.enable = false;

git add nixos/hosts/mysecrets/default.nix
git commit -m "fix(mysecrets): disable auto-upgrade during decommission grace period"
just nix deploy mysecrets
```

### Step 5.3: Decommission mysecrets (Day 30+)

**Prerequisites:**
- 30 days stable operation on hawk
- No rollback incidents
- All backups verified

```bash
ssh mysecrets.internal

# Final backup (archive)
sudo tar -czvf /tmp/mysecrets-final-archive-$(date +%Y%m%d).tar.gz /srv/

# Stop and disable services
sudo systemctl disable --now step-ca kanidm vaultwarden postgresql nginx

# Power down
sudo poweroff
```

### Step 5.4: Update Documentation

Files to update:
- [ ] `CLAUDE.md` - Update infrastructure section
- [ ] `docs/README.md` - Update host list
- [ ] This document - Mark as complete

---

## Rollback Procedures

### Scenario 1: Issues During Migration

**If problems occur during maintenance window:**

```bash
# 1. Stop hawk services
ssh hawk.internal
sudo systemctl stop step-ca kanidm vaultwarden nginx

# 2. Relocate YubiKey back to mysecrets
# (Physical action)

# 3. Revert DNS on routy
ssh routy.internal
sudo knotc zone-begin internal
sudo knotc zone-unset internal auth CNAME
sudo knotc zone-set internal auth 300 CNAME mysecrets
sudo knotc zone-commit internal

# 4. Restart mysecrets services
ssh mysecrets.internal
sudo systemctl start step-ca kanidm vaultwarden nginx

# 5. Verify mysecrets operational
curl -I https://auth.internal/
```

### Scenario 2: Issues After Migration

**If problems discovered in first 7 days:**

1. Keep mysecrets in standby (services stopped but data intact)
2. YubiKey can be moved back if needed
3. Full state preserved on mysecrets /srv

### Scenario 3: Data Recovery

**If data loss occurs:**

```bash
# Restore from backup
ssh hawk.internal

# Kanidm
sudo systemctl stop kanidm
sudo rm -rf /srv/kanidm/*
sudo tar -xzf /path/to/backup/kanidm-backup.tar.gz -C /srv/kanidm/
sudo chown -R kanidm:kanidm /srv/kanidm
sudo systemctl start kanidm

# Vaultwarden (PostgreSQL)
sudo systemctl stop vaultwarden
sudo -u postgres dropdb vaultwarden
sudo -u postgres createdb vaultwarden
gunzip -c /path/to/backup/vaultwarden-db.sql.gz | sudo -u postgres psql vaultwarden
sudo systemctl start vaultwarden
```

---

## Risk Assessment

### High Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| YubiKey not available | CRITICAL | Low | Verify availability before scheduling |
| YubiKey damaged during move | CRITICAL | Very Low | Handle carefully, have recovery plan |
| Database corruption | High | Low | Multiple backups, test restore |

### Medium Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| State version mismatch (Kanidm) | Medium | Medium | Test schema upgrade beforehand |
| ACME cert failures | Medium | Low | Force renewal, verify step-ca first |
| DNS propagation delay | Medium | Low | Short TTL (300s) |

### Low Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| File permission errors | Low | Medium | Scripted ownership fix |
| Service startup order | Low | Low | Explicit dependency in systemd |

---

## Estimated Timeline

| Phase | Duration | Notes |
|-------|----------|-------|
| Configuration prep | 1-2 hours | Can be done ahead of maintenance |
| Secrets migration | 30 minutes | SOPS operations |
| Build validation | 30 minutes | nix build |
| **Maintenance window** | **2-4 hours** | Services unavailable |
| Validation | 1-2 hours | Testing all services |
| Monitoring period | 7 days | Daily checks |
| Decommission | 1 hour | After 30-day grace |

**Total project duration:** ~38 days (including grace periods)

---

## Open Questions

1. **Kanidm schema upgrade**: Need to verify 23.11 → 25.11 compatibility
2. **Backup automation**: Does hawk have backup timers configured?
3. **Tailscale configuration**: Is hawk already in the tailnet?

---

## References

- Forgejo migration (precedent): `docs/migration/forgejo-eagle-to-hawk-migration.md`
- Kanidm administration: `docs/guides/identity/kanidm-user-management.md`
- SOPS secrets management: `CLAUDE.md` (Secrets Management section)
- mysecrets configuration: `nixos/hosts/mysecrets/`
- hawk configuration: `nixos/hosts/hawk/`

---

**Document Version:** 1.0
**Last Updated:** 2026-02-01
