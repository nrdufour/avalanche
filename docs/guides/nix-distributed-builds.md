# Nix Distributed Builds & Binary Caching

## Problem

**Cross-architecture builds are slow or impractical:**
- Hawk (x86_64, Beelink SER5 Max) can emulate aarch64 via QEMU binfmt, but turbo boost must be disabled to prevent crashes — making emulated builds slow
- 3 identical opi nodes (aarch64, Orange Pi 5 Plus) each rebuild the same packages independently
- Kernel builds take ~40 minutes per machine; deploying opi01-03 sequentially wastes 80 minutes on redundant work

**No build sharing:**
- Daily GC (`--delete-older-than 7d` in `nixos/profiles/global/nix.nix`) cleans up store paths with no protection for cross-machine builds
- Official cache.nixos.org doesn't carry custom kernel configs or local packages

## Solution

Two complementary systems:

1. **Distributed builds** — hawk delegates aarch64 derivations to opi01-03 over SSH; x86_64 builds stay local (native, fast)
2. **Binary cache (Harmonia)** — hawk serves its `/nix/store` over HTTP; ARM builds are copied back from opi nodes and pinned with GC roots so other machines (and future rebuilds) pull from cache

## Architecture

```
                        ┌────────────────────────┐
                        │  hawk (x86_64)         │
                        │  - Harmonia cache :5000 │
                        │  - GC roots in          │
                        │    /nix/var/nix/gcroots/ │
                        │    arm-cache/            │
                        └──────┬─────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
        ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐
        │  opi01     │   │  opi02     │   │  opi03     │
        │  aarch64   │   │  aarch64   │   │  aarch64   │
        │  builder   │   │  builder   │   │  builder   │
        └───────────┘   └───────────┘   └───────────┘

Deploy opi03 from hawk:
  1. hawk delegates aarch64 build → opi03 builds natively
  2. Build result copied back → hawk stores in /nix/store
  3. Post-copy script creates GC root → survives daily GC
  4. hawk deploys to opi03

Deploy opi01/02 from hawk:
  1. hawk delegates aarch64 build → checks hawk's Harmonia
  2. Kernel already cached → downloaded in ~1 min
  3. hawk deploys to opi01/02

Calypso can also use hawk as a substituter and build coordinator.
```

## Configuration

### 1. Builder User on opi01-03

Create a dedicated `nix-builder` user on each opi node:

```nix
# nixos/profiles/role-nix-builder.nix (or inline in opi host configs)
{
  users.users.nix-builder = {
    isSystemUser = true;
    group = "nix-builder";
    createHome = true;
    home = "/var/lib/nix-builder";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3Nza... hawk-nix-builder"
      "ssh-ed25519 AAAAC3Nza... calypso-nix-builder"
    ];
  };

  users.groups.nix-builder = {};

  nix.settings.trusted-users = [ "nix-builder" ];
}
```

Generate SSH keys on hawk and calypso:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_nix_builder -C "hawk-nix-builder"
```

### 2. Distributed Builds on hawk (and optionally calypso)

```nix
# nixos/hosts/hawk/nix-builder.nix
{
  nix.buildMachines = [
    {
      hostName = "opi01.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/etc/nix/builder-key";
      maxJobs = 6;   # 8 cores, leave headroom for K3s
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
    {
      hostName = "opi02.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/etc/nix/builder-key";
      maxJobs = 6;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
    {
      hostName = "opi03.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/etc/nix/builder-key";
      maxJobs = 6;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
  ];

  nix.distributedBuilds = true;

  # Let builders pull from cache.nixos.org directly
  nix.settings.builders-use-substitutes = true;
}
```

x86_64 builds stay local on hawk (native). Only aarch64 derivations are delegated.

### 3. Harmonia Binary Cache on hawk

[Harmonia](https://github.com/nix-community/harmonia) is a high-performance Nix binary cache server (faster than nix-serve).

```nix
# nixos/hosts/hawk/harmonia.nix
{
  services.harmonia = {
    enable = true;
    signKeyPaths = [ "/var/lib/harmonia/cache-priv-key.pem" ];
    settings.bind = "[::]:5000";
  };

  networking.firewall.allowedTCPPorts = [ 5000 ];
}
```

One-time key generation:

```bash
nix-store --generate-binary-cache-key hawk.internal /var/lib/harmonia/cache-priv-key.pem /var/lib/harmonia/cache-pub-key.pem
```

### 4. GC Root Management

After ARM builds are copied back to hawk, create GC roots so daily GC doesn't collect them.

**Post-copy script** (`/etc/nix/pin-arm-cache.sh`):

```bash
#!/bin/sh
set -eu
set -f
export IFS=' '

GCROOT_DIR="/nix/var/nix/gcroots/arm-cache"
mkdir -p "$GCROOT_DIR"

for path in $OUT_PATHS; do
  name=$(basename "$path")
  ln -sfn "$path" "$GCROOT_DIR/$name"
done
```

```nix
# In hawk's config
environment.etc."nix/pin-arm-cache.sh" = {
  text = builtins.readFile ./pin-arm-cache.sh;
  mode = "0755";
};
```

**Weekly cleanup timer** — prune GC roots older than 30 days:

```nix
systemd.services.prune-arm-cache-roots = {
  description = "Prune old ARM cache GC roots";
  serviceConfig.Type = "oneshot";
  script = ''
    find /nix/var/nix/gcroots/arm-cache -type l -mtime +30 -delete
  '';
};

systemd.timers.prune-arm-cache-roots = {
  description = "Weekly prune of ARM cache GC roots";
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "weekly";
    Persistent = true;
  };
};
```

The daily GC in `nixos/profiles/global/nix.nix` (`--delete-older-than 7d`) respects these roots — pinned store paths and their dependencies survive collection.

### 5. Substituter Config on All Machines

Add hawk's Harmonia as a substituter in `nixos/profiles/global/nix.nix`:

```nix
nix.settings = {
  substituters = [
    "https://cache.nixos.org"
    "http://hawk.internal:5000"
  ];

  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "hawk.internal:XXXXXXXX"  # contents of /var/lib/harmonia/cache-pub-key.pem
  ];
};
```

## Usage Examples

### Deploy opi03 (first ARM build, populates cache)

```bash
# On hawk (or calypso with distributed builds configured)
just nix deploy opi03

# What happens:
# 1. hawk evaluates opi03's config (x86_64 — local)
# 2. aarch64 derivations delegated to opi03 via SSH
# 3. opi03 builds kernel natively (~40 min)
# 4. Build results copied back to hawk's /nix/store
# 5. Post-copy hook creates GC roots
# 6. hawk deploys closure to opi03
```

### Deploy opi01 and opi02 (cache hits)

```bash
just nix deploy opi01
just nix deploy opi02

# What happens:
# 1. hawk evaluates opi01/02's config
# 2. aarch64 derivations found in hawk's store (cache hit)
# 3. No remote build needed — downloaded from Harmonia in ~1 min
# 4. hawk deploys closure to opi01/02

# Total for all 3: ~44 min (vs ~120 min without caching)
```

### Build ARM package from hawk for testing

```bash
ssh hawk.internal
cd /srv/avalanche
nix build .#nixosConfigurations.opi03.config.system.build.toplevel
# Delegates to opi node, result cached on hawk
```

## Verification

### Check distributed builds are working

```bash
# On hawk
nix build --print-build-logs .#nixosConfigurations.opi03.config.system.build.toplevel

# Look for:
# building '/nix/store/...-linux-6.x.drv' on 'ssh://opi03.internal'
```

### Check Harmonia is serving

```bash
curl http://hawk.internal:5000/nix-cache-info
# Should return: StoreDir: /nix/store

journalctl -fu harmonia
# Shows requests from other machines
```

### Check GC roots exist

```bash
ls /nix/var/nix/gcroots/arm-cache/
# Should show symlinks to aarch64 store paths
```

### Check a path is cached

```bash
nix path-info --store http://hawk.internal:5000 /nix/store/...-linux-6.x
# Should succeed if the path is in hawk's store and signed
```

## Troubleshooting

### Builds not delegating to opi nodes

- **SSH key issue**: Test with `ssh -i /etc/nix/builder-key nix-builder@opi01.internal`
- **Builder offline**: Nix falls back to local build (QEMU) if no builders respond
- **Wrong system**: Verify `systems = [ "aarch64-linux" ]` in buildMachines config
- **Verbose output**: `nix build --verbose` shows builder selection

### Cache misses (machines rebuilding instead of downloading)

- **Key mismatch**: Verify `trusted-public-keys` matches hawk's signing key
- **Harmonia down**: `curl http://hawk.internal:5000/nix-cache-info`
- **Path not signed**: Harmonia only serves paths signed with its key; paths must exist in hawk's store
- **Firewall**: Ensure port 5000 is open on hawk

### GC collecting cached paths

- **Missing GC root**: Check `/nix/var/nix/gcroots/arm-cache/` for the expected symlink
- **Root pruned too early**: Adjust the 30-day threshold in the cleanup timer
- **Dangling symlink**: The target store path was manually deleted; re-build and re-pin

## Security Notes

- All communication over Tailscale (encrypted mesh) — HTTP for Harmonia is fine on trusted network
- `nix-builder` user is a restricted system user (no sudo, no login shell)
- Dedicated SSH keys for builds (separate from user keys)
- Harmonia signing key ensures clients only trust paths signed by hawk

## Related Documentation

- [GitHub Outage Mitigation](github-outage-mitigation.md) — local nixpkgs mirror on Forgejo
- [NixOS Manual: Distributed Builds](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html)
- [Harmonia](https://github.com/nix-community/harmonia) — Nix binary cache server

---

**Created**: 2025-12-30
**Last Updated**: 2026-02-06
**Status**: Ready for implementation
