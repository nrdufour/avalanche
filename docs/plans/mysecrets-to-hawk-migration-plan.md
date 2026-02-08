# Identity Infrastructure Migration: mysecrets → hawk

**Created:** 2026-02-01
**Revised:** 2026-02-08
**Status:** 📋 Planning
**Target Date:** TBD

## Progress Tracking

| Phase | Status | Date | Notes |
|-------|--------|------|-------|
| Feasibility analysis | ✅ Complete | 2026-02-01 | All services portable, YubiKey is critical blocker |
| Plan document | ✅ Complete | 2026-02-08 | Revised: service-by-service with ca.internal |
| Phase 0: ca.internal CNAME | ⏳ Pending | - | DNS alias + fleet-wide ACME URL update |
| Phase 1: step-ca migration | ⏳ Pending | - | YubiKey relocation, config, deploy |
| Phase 2: Kanidm migration | ⏳ Pending | - | Config, data transfer, deploy |
| Phase 3: Vaultwarden migration | ⏳ Pending | - | PostgreSQL merge, data transfer, deploy |
| Phase 4: Cleanup | ⏳ Pending | - | Decommission mysecrets, clean up eagle/beacon |

---

## Executive Summary

This plan covers migrating the identity infrastructure stack from **mysecrets** (Raspberry Pi 4, aarch64) to **hawk** (Beelink SER5, x86_64), one service at a time.

### Motivation

- **Decommission RPi4 hardware**: mysecrets runs on an SD card + USB drive — fragile and slow
- **Reduce host count**: eagle (already down) and beacon (already down) can be formally retired alongside mysecrets, taking the fleet from 17 to 14 managed hosts
- **Consolidate infrastructure services**: hawk already runs Forgejo; adding identity services makes it the single infrastructure box

### Services to Migrate

| Service | Purpose | Data | Phase |
|---------|---------|------|-------|
| step-ca | Certificate Authority | BadgerDB + YubiKey HSM | Phase 1 |
| Kanidm | Identity Management | SQLite-like database (~MB) | Phase 2 |
| Vaultwarden | Password Manager | PostgreSQL database | Phase 3 |

### Critical Constraint: YubiKey Hardware Token

**The step-ca intermediate CA private key is stored on a physical YubiKey** configured at `yubikey:slot-id=9c`. This hardware token MUST be physically relocated to hawk before step-ca can function.

---

## Migration Strategy: Service-by-Service with ca.internal

### Why service-by-service (not all-at-once)

The original plan recommended all-at-once migration. After review, service-by-service is better because:

1. **`ca.internal` decouples the dependency chain.** By introducing a DNS alias for step-ca first, the tight coupling between services (step-ca → ACME → everything) becomes a simple CNAME flip. Services no longer need to move together.
2. **Smaller blast radius per phase.** Each migration is isolated — if Kanidm has issues, Vaultwarden is unaffected.
3. **PostgreSQL merge gets its own phase.** The trickiest part (merging Vaultwarden's PG database into hawk's existing Forgejo PG instance) is isolated from the other migrations.
4. **Flexible scheduling.** Each phase can happen days or weeks apart. No need for a single long maintenance window.

### Migration Order

| Phase | Service | Prerequisite | Downtime |
|-------|---------|-------------|----------|
| 0 | ca.internal CNAME + fleet ACME update | None | Zero (preparatory) |
| 1 | step-ca | Phase 0, YubiKey available | ~30 min (CA offline) |
| 2 | Kanidm | Phase 1 complete | ~30 min (auth offline) |
| 3 | Vaultwarden + PostgreSQL merge | Phase 1 complete | ~1 hour (passwords offline) |

Phases 2 and 3 are independent of each other — they can happen in either order or in parallel.

---

## Architecture Comparison

| Aspect | mysecrets (Source) | hawk (Destination) |
|--------|-------------------|-------------------|
| Architecture | aarch64-linux (ARM) | x86_64-linux (AMD) |
| Hardware | Raspberry Pi 4, 4GB RAM | Beelink SER5 Max, 24GB RAM |
| Storage | SD card + USB drive (/srv) | NVMe + ext4 (/srv) |
| State Version | 23.11 | 25.11 |
| Current Services | step-ca, Kanidm, Vaultwarden | Forgejo, PostgreSQL (forgejo DB) |
| Network | Tailscale client | Tailscale client |

### Package Compatibility

All services have x86_64 packages available:
- ✅ step-ca (pure Go)
- ✅ Kanidm (Rust, both archs supported)
- ✅ Vaultwarden (Rust, both archs supported)
- ✅ PostgreSQL (universal)

---

## Phase 0: Introduce ca.internal (Zero Downtime)

**Goal:** Decouple the ACME CA URL from any specific hostname, so step-ca can move freely in the future.

### Step 0.1: Create ca.internal DNS Record

```bash
ssh routy.internal

# Add ca.internal CNAME pointing to mysecrets (current location)
sudo knotc zone-begin internal
sudo knotc zone-set internal ca 300 CNAME mysecrets
sudo knotc zone-commit internal

# Verify
dig @localhost ca.internal +short
# Expected: mysecrets.internal. then its IP
```

### Step 0.2: Update Fleet-Wide ACME Default

This is a **single file change** — the global ACME module applies to all hosts:

**File:** `nixos/modules/nixos/security/acme.nix`

```nix
{
  ## Defaulting to the local step-ca server (via ca.internal alias)

  security.acme = {
    acceptTerms = true;
    defaults = {
      webroot = "/var/lib/acme/acme-challenge";
      server = "https://ca.internal:8443/acme/acme/directory";
      email = "nrdufour@gmail.com";
    };
  };
}
```

### Step 0.3: Update mysecrets Kanidm ACME Override

The Kanidm config on mysecrets has a hardcoded ACME URL that overrides the global default:

**File:** `nixos/hosts/mysecrets/kanidm/default.nix`

Change `mysecrets.internal:8443` → `ca.internal:8443` in the `security.acme.certs` and `extraLegoFlags` sections.

### Step 0.4: Update step-ca dnsNames

**File:** `nixos/hosts/mysecrets/step-ca/default.nix`

Add `ca.internal` to the `dnsNames` array so the step-ca TLS certificate is valid when accessed via the alias:

```json
"dnsNames": [
  "ca.internal",
  "mysecrets.internal",
  "mysecrets.home.arpa",
  "192.168.20.99"
]
```

### Step 0.5: Deploy and Validate

```bash
# Commit and push
git add nixos/modules/nixos/security/acme.nix
git add nixos/hosts/mysecrets/
git commit -m "feat: introduce ca.internal alias for step-ca

Decouples ACME CA URL from mysecrets hostname. All hosts now use
ca.internal:8443 for ACME, which is a CNAME to mysecrets for now.
This enables moving step-ca to hawk without fleet-wide config changes."

git push

# Deploy mysecrets first (it hosts step-ca with the new dnsNames)
just nix deploy mysecrets

# Then deploy remaining hosts gradually (safe — ca.internal resolves to mysecrets)
just nix deploy hawk
just nix deploy routy
# ... etc, or let auto-upgrade pick it up
```

**Validation:** After deploy, verify ACME still works on any host:
```bash
ssh hawk.internal
sudo systemctl restart acme-forge.internal.service  # or whatever cert hawk has
sudo systemctl status acme-forge.internal.service
# Should succeed using ca.internal:8443
```

**This phase can be done immediately and independently of all other phases.**

---

## Phase 1: Migrate step-ca (YubiKey Required)

**Downtime:** ~30 minutes (certificate issuance unavailable — existing certs continue working)

### Pre-Phase Checklist

- [ ] Phase 0 complete and validated
- [ ] YubiKey physically available
- [ ] USB port on hawk accessible
- [ ] hawk `/srv` has space (~1GB for step-ca data)

### Step 1.1: Prepare hawk step-ca Configuration

```bash
mkdir -p nixos/hosts/hawk/step-ca
cp nixos/hosts/mysecrets/step-ca/default.nix nixos/hosts/hawk/step-ca/
cp -r nixos/hosts/mysecrets/step-ca/resources nixos/hosts/hawk/step-ca/
```

**Required modifications to `nixos/hosts/hawk/step-ca/default.nix`:**

Update `dnsNames` to include hawk:
```json
"dnsNames": [
  "ca.internal",
  "hawk.internal",
  "hawk.home.arpa"
]
```

Note: `mysecrets.internal` and `192.168.20.99` are removed — they belong to the old host.

### Step 1.2: Add step-ca Secrets to hawk

```bash
# Decrypt mysecrets secrets
sops -d secrets/mysecrets/secrets.sops.yaml > /tmp/mysecrets-plain.yaml

# Add to hawk secrets
sops secrets/hawk/secrets.sops.yaml
# Add: stepca_intermediate_password, stepca_yubikey_pin

# Secure cleanup
shred -u /tmp/mysecrets-plain.yaml
```

### Step 1.3: Update hawk/default.nix

```nix
imports = [
  ./hardware-configuration.nix
  ./secrets.nix
  ./forgejo
  ./step-ca        # ADD
];
```

### Step 1.4: Build Validation

```bash
nix build .#nixosConfigurations.hawk.config.system.build.toplevel
```

### Step 1.5: Migration Execution

```bash
# 1. Stop step-ca on mysecrets
ssh mysecrets.internal "sudo systemctl stop step-ca"

# 2. Transfer step-ca data (BadgerDB)
ssh mysecrets.internal "sudo tar -cf - /var/lib/step-ca" | \
  ssh hawk.internal "sudo tar -xf - -C /"
ssh hawk.internal "sudo chown -R step-ca:step-ca /var/lib/step-ca"

# 3. Physically move YubiKey: mysecrets → hawk

# 4. Verify YubiKey on hawk
ssh hawk.internal "lsusb | grep -i yubi"
ssh hawk.internal "ykman info"

# 5. Deploy hawk
just nix deploy hawk

# 6. Verify step-ca running
ssh hawk.internal "systemctl status step-ca"

# 7. Flip ca.internal DNS
ssh routy.internal
sudo knotc zone-begin internal
sudo knotc zone-unset internal ca CNAME
sudo knotc zone-set internal ca 300 CNAME hawk
sudo knotc zone-commit internal

# 8. Validate certificate issuance via ca.internal
step ca certificate test.internal test.crt test.key \
  --ca-url https://ca.internal:8443 \
  --provisioner acme
rm test.crt test.key
```

### Step 1.6: Disable step-ca on mysecrets

Remove or comment out `./step-ca` import from `nixos/hosts/mysecrets/default.nix`. Deploy mysecrets.

### Rollback

If step-ca on hawk fails:
1. Move YubiKey back to mysecrets
2. Flip `ca.internal` CNAME back to mysecrets
3. Restart step-ca on mysecrets

No other hosts need any changes — they all use `ca.internal`.

---

## Phase 2: Migrate Kanidm

**Downtime:** ~30 minutes (identity/OIDC unavailable)

**Can happen independently of Phase 3.** Only requires Phase 1 complete (step-ca on hawk for local ACME).

### Step 2.1: Prepare hawk Kanidm Configuration

```bash
mkdir -p nixos/hosts/hawk/kanidm
cp nixos/hosts/mysecrets/kanidm/default.nix nixos/hosts/hawk/kanidm/
```

**Required modifications:**

1. **Remove the hardcoded ACME override.** The global default (`ca.internal:8443`) is correct. Remove or update the `security.acme.certs."auth.internal"` block and `extraLegoFlags` that reference `mysecrets.internal:8443`.

2. **Update the root CA import path.** Change:
   ```nix
   security.pki.certificateFiles = [ ../step-ca/resources/root_ca.crt ];
   ```
   This path works as-is if step-ca is also on hawk (Phase 1). Verify.

3. **Bind mount path.** Verify `/srv/kanidm` exists on hawk or will be created by tmpfiles rules.

### Step 2.2: Add Kanidm Secrets to hawk

```bash
sops secrets/hawk/secrets.sops.yaml
# Add: kanidm_admin_password
```

### Step 2.3: Update hawk/default.nix

```nix
imports = [
  ./hardware-configuration.nix
  ./secrets.nix
  ./forgejo
  ./step-ca
  ./kanidm         # ADD
];
```

### Step 2.4: Backup and Transfer Kanidm Data

```bash
# Trigger fresh backup
ssh mysecrets.internal "sudo systemctl start kanidm-backup.service"

# Stop Kanidm on mysecrets
ssh mysecrets.internal "sudo systemctl stop kanidm"

# Transfer data
ssh mysecrets.internal "sudo tar -cf - /srv/kanidm" | \
  ssh hawk.internal "sudo tar -xf - -C /"
ssh hawk.internal "sudo chown -R kanidm:kanidm /srv/kanidm"
```

### Step 2.5: Deploy and Validate

```bash
just nix deploy hawk

# Verify Kanidm running
ssh hawk.internal "systemctl status kanidm"

# Flip auth.internal DNS
ssh routy.internal
sudo knotc zone-begin internal
sudo knotc zone-unset internal auth CNAME
sudo knotc zone-set internal auth 300 CNAME hawk
sudo knotc zone-commit internal

# Validate
curl -I https://auth.internal/.well-known/openid-configuration
kanidm login --name admin
kanidm person list --name admin
```

### Step 2.6: Disable Kanidm on mysecrets

Remove `./kanidm` import from mysecrets. Deploy.

### Rollback

1. Re-enable Kanidm on mysecrets
2. Flip `auth.internal` CNAME back to mysecrets
3. Deploy mysecrets

---

## Phase 3: Migrate Vaultwarden (PostgreSQL Merge)

**Downtime:** ~1 hour (password manager unavailable)

**Can happen independently of Phase 2.** Only requires Phase 1 complete.

### The PostgreSQL Challenge

hawk already runs PostgreSQL for Forgejo (`nixos/hosts/hawk/forgejo/local-pg.nix`). Vaultwarden also needs PostgreSQL. These two `local-pg.nix` files **cannot coexist as-is** because they both define `services.postgresql` with separate `ensureDatabases`, `authentication`, and `initialScript`.

**Solution:** Create a shared PostgreSQL configuration for hawk that serves both databases.

### Step 3.1: Create Shared PostgreSQL Config

Create `nixos/hosts/hawk/postgresql.nix`:

```nix
{ pkgs, config, ... }:
{
  services.postgresql = {
    enable = true;
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  address          auth-method
      local all       postgres                 peer
      local all       all                      md5
      host  all       all     127.0.0.1/32     md5
      host  all       all     ::1/128          md5
    '';
    dataDir = "/srv/postgresql/${config.services.postgresql.package.psqlSchema}";
    ensureDatabases = [ "forgejo" "vaultwarden" ];
    initialScript = config.sops.templates."pg_init_script.sql".path;
  };

  services.postgresqlBackup = {
    enable = true;
    location = "/srv/backups/postgresql";
  };

  sops.secrets = {
    forgejo_db_password = { owner = "forgejo"; };
    vaultwarden_db_password = {};
  };

  sops.templates."pg_init_script.sql" = {
    owner = "postgres";
    content = ''
      CREATE ROLE forgejo WITH LOGIN PASSWORD '${config.sops.placeholder.forgejo_db_password}';
      GRANT ALL PRIVILEGES ON DATABASE forgejo TO forgejo;
      ALTER DATABASE forgejo OWNER TO forgejo;

      CREATE ROLE vaultwarden WITH LOGIN PASSWORD '${config.sops.placeholder.vaultwarden_db_password}';
      GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
      ALTER DATABASE vaultwarden OWNER TO vaultwarden;
    '';
  };
}
```

**Important:** The `initialScript` only runs on first PostgreSQL init. Since hawk already has a running PG instance, you'll create the vaultwarden role/database manually during migration (Step 3.4).

### Step 3.2: Update Forgejo to Use Shared PostgreSQL

Remove `./local-pg.nix` from `nixos/hosts/hawk/forgejo/default.nix`:

```nix
imports = [
  # ./local-pg.nix        # REMOVE — moved to shared postgresql.nix
  ./forgejo.nix
  ./forgejo-runner.nix
  ./forgejo-rclone.nix
  ./forgejo-restic-remote.nix
];
```

Also remove the `forgejo_db_password` sops secret from `forgejo/local-pg.nix` since it moves to the shared config.

### Step 3.3: Prepare Vaultwarden Config

```bash
mkdir -p nixos/hosts/hawk/vaultwarden
cp nixos/hosts/mysecrets/vaultwarden/vaultwarden.nix nixos/hosts/hawk/vaultwarden/
```

Create `nixos/hosts/hawk/vaultwarden/default.nix` (without `local-pg.nix` — PG is shared now):

```nix
{ ... }: {
  imports = [
    ./vaultwarden.nix
  ];
}
```

Update `vaultwarden.nix` to remove the hardcoded ACME override if it references `mysecrets.internal`.

### Step 3.4: Update hawk/default.nix

```nix
imports = [
  ./hardware-configuration.nix
  ./secrets.nix
  ./postgresql       # ADD — shared PostgreSQL for Forgejo + Vaultwarden
  ./forgejo
  ./step-ca
  ./kanidm
  ./vaultwarden      # ADD
];
```

### Step 3.5: Add Vaultwarden Secrets to hawk

```bash
sops secrets/hawk/secrets.sops.yaml
# Add: vaultwarden_db_password, vaultwarden_admin_token, vaultwarden_smtp_password
```

### Step 3.6: Build and Validate Before Migration

```bash
nix build .#nixosConfigurations.hawk.config.system.build.toplevel
```

**Deploy the shared PostgreSQL config first** (without Vaultwarden data) to make sure Forgejo keeps working:

```bash
just nix deploy hawk

# Verify Forgejo still works
ssh hawk.internal "systemctl status forgejo postgresql"
curl -I https://forge.internal/
```

### Step 3.7: Migrate Vaultwarden Data

```bash
# Dump Vaultwarden database on mysecrets
ssh mysecrets.internal
sudo systemctl stop vaultwarden
sudo -u postgres pg_dump vaultwarden | gzip > /tmp/vaultwarden-db.sql.gz

# Transfer dump to hawk
scp mysecrets.internal:/tmp/vaultwarden-db.sql.gz hawk.internal:/tmp/

# Import on hawk
ssh hawk.internal
sudo -u postgres createdb vaultwarden
sudo -u postgres createuser vaultwarden
gunzip -c /tmp/vaultwarden-db.sql.gz | sudo -u postgres psql vaultwarden
sudo -u postgres psql vaultwarden -c \
  "ALTER ROLE vaultwarden WITH PASSWORD '$(sudo cat /run/secrets/vaultwarden_db_password)';"
sudo -u postgres psql vaultwarden -c "ALTER DATABASE vaultwarden OWNER TO vaultwarden;"

# Verify import
sudo -u postgres psql vaultwarden -c "SELECT COUNT(*) FROM users;"
# Should match pre-migration count
```

### Step 3.8: Start Vaultwarden and Flip DNS

```bash
# Start Vaultwarden
ssh hawk.internal "sudo systemctl start vaultwarden"
ssh hawk.internal "systemctl status vaultwarden"

# Flip DNS
ssh routy.internal
sudo knotc zone-begin internal
sudo knotc zone-unset internal vaultwarden CNAME
sudo knotc zone-set internal vaultwarden 300 CNAME hawk
sudo knotc zone-commit internal

# Validate
curl -I https://vaultwarden.internal/
curl https://vaultwarden.internal/api/config
```

### Rollback

If Vaultwarden on hawk fails:
1. Stop Vaultwarden on hawk
2. Re-enable Vaultwarden on mysecrets, restart
3. Flip DNS back

If the PostgreSQL merge breaks Forgejo:
1. This is why we deploy the shared PG config **before** importing Vaultwarden data
2. The shared config is functionally identical to the Forgejo-only config
3. Worst case: revert to `forgejo/local-pg.nix` and redeploy hawk

---

## Phase 4: Cleanup and Decommission

### Step 4.1: Monitoring Period (7 days per service)

After each phase, monitor for 7 days:

```bash
ssh hawk.internal "systemctl status step-ca kanidm vaultwarden forgejo postgresql"
ssh hawk.internal "journalctl --since yesterday -p err"
ssh hawk.internal "df -h /srv"
```

### Step 4.2: Decommission mysecrets

**Prerequisites:**
- All three services stable on hawk for 7+ days
- No rollback incidents

```bash
# Disable auto-upgrade
# Edit nixos/hosts/mysecrets/default.nix: system.autoUpgrade.enable = false;
just nix deploy mysecrets

# After validation period: power down
ssh mysecrets.internal "sudo poweroff"
```

Keep mysecrets configs in the repo for 30 days as reference, then remove:
- `nixos/hosts/mysecrets/`
- `secrets/mysecrets/`
- Flake entry in `flake.nix`
- `.sops.yaml` creation rules for mysecrets

### Step 4.3: Clean Up eagle and beacon

Both hosts are already powered down. Formally remove:

**eagle** (Forgejo migrated to hawk):
- `nixos/hosts/eagle/`
- `secrets/eagle/`
- Flake entry in `flake.nix`
- `.sops.yaml` creation rules for eagle

**beacon** (nix-serve — evaluate if still needed):
- If binary cache is no longer needed, remove `nixos/hosts/beacon/` and flake entry
- If needed, consider running nix-serve on hawk or as a K3s service

### Step 4.4: Update Documentation

- [ ] `CLAUDE.md` — Update host count (17 → 14), update hawk's service list, remove mysecrets/eagle/beacon from host table
- [ ] `docs/README.md` — Update host list
- [ ] This document — Mark as complete

---

## Risk Assessment

### High Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| YubiKey not available | CRITICAL (blocks Phase 1) | Low | Verify availability before scheduling |
| YubiKey damaged during move | CRITICAL | Very Low | Handle carefully |
| PostgreSQL merge breaks Forgejo | High | Low | Deploy shared PG config before Vaultwarden data import; validate Forgejo first |

### Medium Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| ACME cert failures after ca.internal switch | Medium | Low | Test on one host first in Phase 0 |
| DNS propagation delay | Medium | Low | Short TTL (300s) on all records |
| hawk resource contention (many services) | Medium | Low | 24GB RAM is plenty; monitor after each phase |

### Low Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| File permission errors | Low | Medium | chown after each data transfer |
| Nginx vhost conflicts | Low | Low | NixOS merges nginx configs; verify no contradictions |

---

## Estimated Timeline

| Phase | Duration | Can Start After | Notes |
|-------|----------|----------------|-------|
| Phase 0: ca.internal | 1 hour | Immediately | Zero downtime, deploy gradually |
| Phase 1: step-ca | ~30 min downtime | Phase 0 validated | Requires YubiKey |
| Phase 2: Kanidm | ~30 min downtime | Phase 1 stable | Independent of Phase 3 |
| Phase 3: Vaultwarden | ~1 hour downtime | Phase 1 stable | PG merge adds complexity |
| Phase 4: Cleanup | 1-2 hours | All phases stable 7+ days | Remove old configs |

Phases can be spread across days or weeks. No rush — each phase is independently valuable and independently rollback-safe.

---

## Open Questions

1. ~~**Kanidm schema upgrade**: Need to verify 23.11 → 25.11 compatibility~~ Non-issue: `kanidm_1_8` package comes from nixpkgs input, not stateVersion
2. **Backup automation**: Does hawk have backup timers? The shared postgresql.nix includes `postgresqlBackup` but verify Kanidm backup schedule carries over
3. **beacon**: Is nix-serve still useful, or can it be permanently retired?

---

## References

- Forgejo migration (precedent): `docs/migration/forgejo-eagle-to-hawk-migration.md`
- Kanidm administration: `docs/guides/identity/kanidm-user-management.md`
- SOPS secrets management: `CLAUDE.md` (Secrets Management section)
- Global ACME config: `nixos/modules/nixos/security/acme.nix`
- mysecrets configuration: `nixos/hosts/mysecrets/`
- hawk configuration: `nixos/hosts/hawk/`

---

**Document Version:** 2.0
**Last Updated:** 2026-02-08
