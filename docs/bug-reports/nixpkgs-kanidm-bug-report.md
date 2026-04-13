# kanidm `withSecretProvisioning` causes irreversible domain version upgrade (MG0010DowngradeNotAllowed)

## Description

Using `pkgs.kanidm_1_9.withSecretProvisioning` causes the Kanidm database domain version to be upgraded to **14** (master branch level), even though both the regular and `withSecretProvisioning` binaries target domain level **13**. This makes the database unrecoverable without restoring from backup — neither binary variant can start afterward.

## Affected version

- nixpkgs: `4590696` (unstable, 2026-03-23)
- `kanidm_1_9`: 1.9.2
- `kanidm_1_9.withSecretProvisioning`: 1.9.2

## Steps to reproduce

1. Run Kanidm 1.9.2 (regular package) — works fine, database at domain level 13.
2. Switch to `pkgs.kanidm_1_9.withSecretProvisioning` and deploy.
3. The NixOS module's `ExecStartPre` runs `kanidmd domain rename` using the `withSecretProvisioning` binary — this succeeds (exit 0) but silently upgrades the database to domain level 14.
4. `ExecStart` (`kanidmd server`) then fails:

```
ERROR: domain_previous_version: 14 | domain_target_version: 13
ERROR: Unable to setup query server or idm server -> MG0010DowngradeNotAllowed
ERROR: Failed to start server core!
```

5. Reverting to the regular `pkgs.kanidm_1_9` package does **not** fix the issue — same error, since the DB is now at level 14 and the regular binary also targets 13.

## Root cause (suspected)

The `oauth2-basic-secret-modify.patch` inserts code into the `initialise_helper` function in `migrations.rs` — the same function responsible for domain level upgrades. While the patch does not explicitly change `DOMAIN_TGT_LEVEL`, the inserted code may shift or interact with the migration logic in a way that causes an unintended domain level bump during `domain rename`.

Domain level 14 only exists on Kanidm's `master` branch (unreleased). The v1.9.2 tag has `DOMAIN_TGT_LEVEL = 13`.

## Impact

- **Data-destructive**: The domain version upgrade is irreversible. `kanidmd domain remigrate` requires a running server (admin socket), which can't start.
- **Recovery**: The only fix is restoring from a pre-upgrade backup using the **1.8 binary** (`kanidmd database restore`), since the 1.9 binary refuses to restore 1.8-era backups. The 1.9 binary then re-migrates the restored DB to level 13.
- **Scope**: Affects anyone enabling `services.kanidm.provision` with `idmAdminPasswordFile`, `adminPasswordFile`, or `basicSecretFile` (which require `withSecretProvisioning`).

## Workaround

Use the regular `pkgs.kanidm_1_9` without `basicSecretFile` or `idmAdminPasswordFile`. The provisioning module still works — it auto-recovers the `idm_admin` password on each restart. The only lost functionality is pinning OAuth2 client secrets from files.

## Recovery steps (if already affected)

```bash
# 1. Stop kanidm
sudo systemctl stop kanidm

# 2. Restore from backup using the 1.8 binary (1.9 refuses 1.8 backups)
sudo /nix/store/<kanidm-1.8.x>/bin/kanidmd database restore \
  /path/to/backup.json.gz -c /path/to/server.toml

# 3. Switch back to regular kanidm_1_9 package in NixOS config, deploy

# 4. Start kanidm (will re-migrate from 1.8 to 1.9 domain level 13)
sudo systemctl start kanidm
```

## Environment

- NixOS unstable (nixpkgs `4590696`)
- Kanidm 1.9.2, upgraded from 1.8.6
- `services.kanidm.provision.enable = true` with `basicSecretFile` set on an OAuth2 client
