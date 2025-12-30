# Nix Distributed Builds & Caching

## Problem Statement

**Current Pain Points:**
- Each machine builds independently when deploying
- Kernel builds take 40 minutes **per machine** (opi01, opi02, opi03)
- No build caching between identical machines
- 3 identical opi nodes = 3x wasted compile time (120 min total)
- Can't develop/test builds on eagle (too slow, ARM-only)

**What We Want:**
- Build once, deploy everywhere (for identical configs)
- Distribute builds to appropriate architecture (x86 → SER5, ARM → opi nodes)
- Cache builds for reuse
- Develop on SER5 MAX (fast x86 box) while building for ARM cluster

## Solution Overview

Two complementary systems:

1. **Distributed Builds**: Build on remote machines (right architecture, more power)
2. **Binary Cache**: Share build results between machines (build once, reuse)

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Scenario 1: Calypso Initiates Deploy                           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ calypso (laptop)                                        │    │
│  │ - Runs: just nix deploy opi01                           │    │
│  │ - Coordinates build via distributed builds              │    │
│  │ - Caches result locally                                 │    │
│  └────────┬────────────────────────────────────────────────┘    │
│           │                                                      │
│           ├─→ opi01: Build ARM kernel (40 min, cache result)    │
│           ├─→ opi02: Use cached kernel from opi01               │
│           └─→ opi03: Use cached kernel from opi01               │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Scenario 2: SER5 MAX as Development/Build Machine              │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ ser5.internal (SER5 MAX)                                │    │
│  │ - SSH workstation for development                       │    │
│  │ - Fast x86 builds (native)                              │    │
│  │ - Coordinates ARM builds (via opi nodes)                │    │
│  │ - Central build cache                                   │    │
│  └────────┬────────────────────────────────────────────────┘    │
│           │                                                      │
│           ├─→ x86 builds: Native on SER5 (fast!)                │
│           └─→ ARM builds: Delegated to opi01-03 (native ARM)    │
│                                                                  │
│  Workflow:                                                       │
│  1. SSH to ser5.internal                                        │
│  2. Develop module/package                                      │
│  3. nix build (uses distributed builds + cache)                 │
│  4. just nix deploy (deploys with cached builds)                │
└──────────────────────────────────────────────────────────────────┘
```

## Part 1: Distributed Builds

### What It Solves
- Build ARM packages on ARM hardware (opi nodes)
- Build x86 packages on x86 hardware (SER5 MAX)
- Avoid slow QEMU emulation
- Parallelize builds across multiple machines

### Configuration

#### On Builder Machines (SER5 MAX, opi01-03)

Create a dedicated build user:

```nix
# nixos/profiles/role-server.nix or per-host config
{
  users.users.nix-builder = {
    isSystemUser = true;
    group = "nix-builder";
    createHome = true;
    home = "/var/lib/nix-builder";
    openssh.authorizedKeys.keys = [
      # Public key from calypso
      "ssh-ed25519 AAAAC3Nza... calypso-nix-builder"
      # Public key from SER5 MAX
      "ssh-ed25519 AAAAC3Nza... ser5-nix-builder"
    ];
  };

  users.groups.nix-builder = {};

  nix.settings.trusted-users = [ "nix-builder" ];
}
```

#### On Initiating Machines (calypso, SER5 MAX)

Configure build machines:

```nix
# nixos/hosts/calypso/default.nix
# nixos/hosts/ser5/default.nix (when SER5 arrives)
{
  nix.buildMachines = [
    # SER5 MAX - Fast x86_64 builder
    {
      hostName = "ser5.internal";
      systems = [ "x86_64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/home/ndufour/.ssh/id_nix_builder";
      maxJobs = 12;  # 8 cores, allow some parallelism
      speedFactor = 4;  # 4x faster than opi nodes
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }

    # Orange Pi 5 Plus Controllers - ARM builders
    {
      hostName = "opi01.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/home/ndufour/.ssh/id_nix_builder";
      maxJobs = 6;  # 8 cores, leave headroom for K3s
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
    {
      hostName = "opi02.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/home/ndufour/.ssh/id_nix_builder";
      maxJobs = 6;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
    {
      hostName = "opi03.internal";
      systems = [ "aarch64-linux" ];
      sshUser = "nix-builder";
      sshKey = "/home/ndufour/.ssh/id_nix_builder";
      maxJobs = 6;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    }
  ];

  nix.distributedBuilds = true;

  # Allow builders to use binary cache (faster)
  nix.settings.builders-use-substitutes = true;
}
```

#### SSH Key Setup

```bash
# On calypso
ssh-keygen -t ed25519 -f ~/.ssh/id_nix_builder -C "calypso-nix-builder"

# On SER5 MAX (when it arrives)
ssh-keygen -t ed25519 -f ~/.ssh/id_nix_builder -C "ser5-nix-builder"

# Add public keys to builder machines' authorized_keys (via NixOS config above)
```

## Part 2: Binary Cache (Build Sharing)

### What It Solves
- **Build once, reuse everywhere**
- opi01 builds kernel → opi02 and opi03 reuse the same build
- No more rebuilding identical packages
- 120 minutes (3x 40 min) → 40 minutes (build once)

### Option A: Shared Nix Store (NFS/S3)

**Pros**: Automatic sharing, no server needed
**Cons**: Requires shared filesystem or object storage

```nix
# Mount shared nix store from NFS server
fileSystems."/nix" = {
  device = "possum.internal:/export/nix";
  fsType = "nfs";
};
```

**Not recommended** for Avalanche (adds complexity, single point of failure).

### Option B: Local Binary Cache Server (Recommended)

Run a cache server on **SER5 MAX**:

```nix
# nixos/hosts/ser5/default.nix
{
  services.nix-serve = {
    enable = true;
    secretKeyFile = "/var/lib/nix-serve/cache-priv-key.pem";
    port = 5000;
  };

  # Generate signing key (one-time setup)
  # nix-store --generate-binary-cache-key cache.avalanche.internal /var/lib/nix-serve/cache-priv-key.pem /var/lib/nix-serve/cache-pub-key.pem

  # Allow local network access
  networking.firewall.allowedTCPPorts = [ 5000 ];
}
```

#### On All Other Machines (calypso, opi01-03, etc.)

Configure to use the local cache:

```nix
# nixos/profiles/global.nix or per-host
{
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"  # Official cache (first)
      "http://ser5.internal:5000"  # Local cache (fallback/upload)
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      # Add SER5 cache public key here after generating
      "cache.avalanche.internal:YOUR_PUBLIC_KEY_HERE"
    ];

    # Upload builds to local cache
    post-build-hook = "/etc/nix/upload-to-cache.sh";
  };
}
```

#### Upload Hook Script

Create upload script on machines that build:

```bash
# /etc/nix/upload-to-cache.sh (on calypso, SER5, opi01-03)
#!/bin/sh
set -eu
set -f # disable globbing
export IFS=' '

echo "Uploading paths" $OUT_PATHS
exec nix copy --to http://ser5.internal:5000 $OUT_PATHS
```

```nix
# Make executable in NixOS config
environment.etc."nix/upload-to-cache.sh" = {
  text = ''
    #!/bin/sh
    set -eu
    set -f
    export IFS=' '
    echo "Uploading paths" $OUT_PATHS
    exec nix copy --to http://ser5.internal:5000 $OUT_PATHS
  '';
  mode = "0755";
};
```

### Option C: Simple File-Based Cache (Easiest)

Use a shared directory on possum (Garage S3) or local filesystem:

```nix
# On all machines
nix.settings.extra-substituters = [ "file:///mnt/nix-cache" ];

# Post-build hook copies to shared location
nix.settings.post-build-hook = pkgs.writeShellScript "copy-to-cache" ''
  set -eu
  set -f
  export IFS=' '
  for path in $OUT_PATHS; do
    nix copy --to file:///mnt/nix-cache $path
  done
'';
```

**Recommended for simplicity**: Use SER5 MAX as NFS server for `/mnt/nix-cache`.

## Usage Examples

### Scenario 1: Deploy from Calypso (Current Workflow, Improved)

```bash
# On calypso
cd ~/Documents/code/projects/ops/avalanche

# Deploy opi01 - builds kernel (40 min), uploads to cache
just nix deploy opi01

# Deploy opi02 - downloads kernel from cache (1 min)
just nix deploy opi02

# Deploy opi03 - downloads kernel from cache (1 min)
just nix deploy opi03

# Total time: 42 minutes (vs 120 minutes before!)
```

**What happens:**
1. calypso initiates build for opi01
2. Distributed build system sends ARM build to opi01
3. opi01 builds kernel (40 min)
4. Post-build hook uploads to SER5 cache
5. opi02 deployment finds kernel in cache, downloads instead of rebuilding
6. opi03 deployment finds kernel in cache, downloads instead of rebuilding

### Scenario 2: Develop on SER5 MAX (New Workflow)

```bash
# SSH to SER5 MAX
ssh ser5.internal

# Clone avalanche repo (or use shared mount)
cd /srv/avalanche

# Develop new module
vim nixos/modules/nixos/my-feature.nix

# Test build for ARM (uses opi nodes via distributed builds)
nix build .#nixosConfigurations.opi01.config.system.build.toplevel
# Kernel builds on opi01, cached on SER5

# Test build for x86
nix build .#nixosConfigurations.cardinal.config.system.build.toplevel
# Builds natively on SER5 (fast!)

# Deploy to cluster (uses cached builds)
just nix deploy opi01  # Uses cache, fast!
just nix deploy opi02  # Uses cache, fast!
just nix deploy opi03  # Uses cache, fast!
```

**Benefits:**
- Fast x86 builds (native on SER5)
- ARM builds delegated to opi nodes (no emulation)
- All builds cached centrally on SER5
- Can work disconnected from calypso

### Kernel Build Parallelization

With 3 opi nodes, kernel builds can be parallelized:

```nix
# In nixos/profiles/hw-orange-pi-5-plus.nix or similar
boot.kernelPackages = pkgs.linuxPackages_latest.override {
  kernel = pkgs.linuxPackages_latest.kernel.override {
    enableParallelBuilding = true;
  };
};
```

**Result:**
- Each opi node uses 6-8 cores for kernel compilation
- With distributed builds, Nix can split work across multiple opi nodes
- 40 min → potentially 15-20 min with good parallelization

## Verification

### Check Distributed Builds Working

```bash
# On calypso or SER5
nix build --print-build-logs .#nixosConfigurations.opi01.config.system.build.toplevel

# Look for lines like:
# building '/nix/store/...-linux-6.6.60.drv' on 'ssh://opi01.internal'
```

### Check Cache Working

```bash
# On any machine
nix-store --query --requisites /nix/store/...-linux-6.6.60 | wc -l
# Shows dependencies

# Check if path is in cache
nix path-info --store http://ser5.internal:5000 /nix/store/...-linux-6.6.60
# Should succeed if cached
```

### Monitor Cache Activity

```bash
# On SER5 MAX
journalctl -fu nix-serve

# You'll see requests from other machines fetching builds
```

## Troubleshooting

### Builds Not Using Remote Builders

**Symptom**: Builds still happen locally

**Check**:
```bash
nix build --print-build-logs --verbose .#nixosConfigurations.opi01.config.system.build.toplevel
# Look for "building on ssh://..." messages
```

**Common fixes**:
- SSH key not authorized: Add public key to builder's config
- Builder offline: Check `ssh nix-builder@opi01.internal`
- Wrong architecture: Verify `systems = [ "aarch64-linux" ]` matches build

### Cache Not Being Used

**Symptom**: Machines rebuild instead of downloading

**Check**:
```bash
# On machine that should use cache
nix-store --query --deriver /nix/store/...-linux-6.6.60
# Should show it was fetched from cache, not built locally
```

**Common fixes**:
- Public key mismatch: Verify cache public key in `trusted-public-keys`
- Cache server down: Check `curl http://ser5.internal:5000/nix-cache-info`
- Post-build hook not running: Check `/etc/nix/upload-to-cache.sh` exists and is executable

### SSH Authentication Issues

```bash
# Test SSH manually
ssh -i ~/.ssh/id_nix_builder nix-builder@opi01.internal

# Debug verbose
ssh -v -i ~/.ssh/id_nix_builder nix-builder@opi01.internal
```

## Performance Expectations

### Current State (No Distributed Builds, No Cache)
```
Deploy opi01: 40 min (build kernel on opi01)
Deploy opi02: 40 min (build kernel on opi02)
Deploy opi03: 40 min (build kernel on opi03)
────────────────────────────────────────────
Total:        120 min
```

### With Distributed Builds + Cache
```
Deploy opi01: 40 min (build kernel on opi01, upload to cache)
Deploy opi02:  2 min (download from cache)
Deploy opi03:  2 min (download from cache)
────────────────────────────────────────────
Total:         44 min (63% time savings!)
```

### With SER5 as Development Box
```
Develop on SER5:  Fast (native x86, local dev environment)
Build ARM:        40 min (delegated to opi01, cached)
Build x86:         2 min (native on SER5, fast!)
Deploy cluster:    6 min (3x 2min downloads from cache)
────────────────────────────────────────────
Total workflow:   ~48 min (vs 120+ min before)
```

## Security Considerations

**Trust Model:**
- Remote builders are **trusted** (can execute arbitrary code)
- Only add builders you control
- Binary cache is **unsigned by default** (use signing keys for production)

**Network:**
- All communication over Tailscale (encrypted mesh)
- SSH provides additional layer
- nix-serve uses HTTP (no TLS) - fine on trusted network

**Hardening:**
- Use dedicated SSH keys for builds (separate from user keys)
- Limit nix-builder user permissions (no sudo, restricted shell)
- Consider signing cache with `nix-store --generate-binary-cache-key`

## Next Steps

1. **When SER5 MAX arrives (2026-01-02):**
   - Install NixOS
   - Configure as build coordinator (distributed builds + cache server)
   - Migrate Forgejo from eagle → SER5 MAX

2. **On calypso:**
   - Add distributed build configuration
   - Generate SSH key for remote builds
   - Test kernel build with caching

3. **On opi01-03:**
   - Add nix-builder user
   - Configure to use SER5 cache
   - Test cache uploads

4. **Migrate Development Workflow:**
   - SSH to SER5 for development
   - Use SER5 as primary build coordinator
   - Keep calypso for portable deployments

## Related Documentation

- [GitHub Outage Mitigation](github-outage-mitigation.md) - Local nixpkgs mirror
- CLAUDE.md - Infrastructure overview
- NixOS Manual: [Distributed Builds](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html)
- NixOS Manual: [Binary Cache](https://nixos.org/manual/nix/stable/package-management/binary-cache.html)

---

**Created**: 2025-12-30
**Last Updated**: 2025-12-30
**Status**: 🚧 Ready for implementation when SER5 MAX arrives (2026-01-02)
