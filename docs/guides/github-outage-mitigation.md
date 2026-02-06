# GitHub Outage Mitigation

## Overview

Avalanche maintains a local mirror of nixpkgs at `forge.internal/Mirrors/nixpkgs` to mitigate GitHub dependency. This mirror:
- Syncs from `github:nixos/nixpkgs` every 8 hours
- Contains all branches (nixos-25.11, nixos-unstable, master, etc.)
- Hosted on hawk.internal using Forgejo

## When to Use the Mirror

Use the local mirror when:
- GitHub is experiencing an outage
- You need to update flake inputs but GitHub is unreachable
- You want to reduce external network dependency during deployments

## Using the Mirror During GitHub Outages

### Temporary Override (Recommended)

Override nixpkgs input for a single operation without modifying flake.nix:

```bash
# Update nixpkgs from local mirror
nix flake lock --override-input nixpkgs github:Mirrors/nixpkgs/nixos-25.11

# Update unstable from local mirror
nix flake lock --override-input nixpkgs-unstable github:Mirrors/nixpkgs/nixos-unstable

# Deploy with overridden inputs
just nix deploy <hostname>
```

### Permanent Switch (Not Recommended)

If you need to permanently switch to the mirror (e.g., extended GitHub outage):

1. Edit `flake.nix`:
   ```nix
   nixpkgs.url = "github:Mirrors/nixpkgs/nixos-25.11";
   nixpkgs-unstable.url = "github:Mirrors/nixpkgs/nixos-unstable";
   ```

2. Update and commit:
   ```bash
   nix flake update
   git add flake.nix flake.lock
   git commit -m "Switch to local nixpkgs mirror"
   ```

3. **Remember to revert when GitHub is back online**

## Reverting to GitHub

After the outage resolves:

```bash
# If you used temporary override, just update normally:
nix flake update

# If you modified flake.nix, revert the changes:
git revert <commit-hash>
nix flake update
```

## Limitations

- **Initial fetch is slow**: First use of mirror requires substantial download (~4GB)
- **Nginx timeouts**: HTTPS access may timeout on large git operations; use temporary overrides sparingly
- **Sync lag**: Mirror syncs every 8 hours, may be behind GitHub by up to 8 hours
- **No SSH support**: Mirror only accessible via HTTPS (public repo)

## Mirror Maintenance

### Check Mirror Status

```bash
# View last sync time
ssh hawk.internal sudo -u postgres psql forgejo -t -c \
  "SELECT r.name, m.last_update FROM repository r \
   JOIN mirror m ON r.id = m.repo_id WHERE r.name = 'nixpkgs';"

# Check mirror disk usage
ssh hawk.internal sudo du -sh /srv/forgejo/repositories/mirrors/nixpkgs.git
```

### Manual Sync

```bash
# Trigger immediate sync via Forgejo web UI
# Repository → Settings → Mirror Settings → "Synchronize Now"
```

### Adjust Sync Interval

In Forgejo web UI:
- Repository → Settings → Mirror Settings
- Change "Sync Interval" (default: 8h)
- Consider 4h for more frequent updates, or 12h to reduce load

## Related Documentation

- Network architecture: `docs/architecture/network/tailscale-architecture.md`
- Forgejo configuration: `nixos/hosts/hawk/forgejo/forgejo.nix`
