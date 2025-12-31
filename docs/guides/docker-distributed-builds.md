# Docker Distributed Builds & Caching

## Problem Statement

**Current Pain Points:**
- Multi-architecture Docker builds use QEMU emulation (slow)
- Building ARM64 images on x86 takes 3-5x longer than native
- Building AMD64 images on ARM64 (eagle) uses emulation
- No architecture-aware build routing
- Forgejo Actions workflows can't leverage native architecture builders

**What We Want:**
- Build AMD64 images on x86 hardware (SER5 MAX)
- Build ARM64 images on ARM hardware (opi nodes or eagle)
- Avoid QEMU emulation overhead
- Parallel multi-arch builds (build both architectures simultaneously)
- Reuse infrastructure from Nix distributed builds (same SSH keys, same builder hosts)

## Solution Overview

Two complementary approaches:

1. **BuildKit Remote Workers**: Configure BuildKit to use remote builders (architecture-aware routing)
2. **Docker Buildx Multi-Node**: Create multi-node builder instances (more flexible, runtime configuration)

**Recommended**: BuildKit remote workers via `buildkitd.toml` (simpler, automatic, system-wide).

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Scenario 1: Forgejo Actions Workflow (eagle host)              │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Forgejo Runner (eagle.internal)                         │    │
│  │ - Runs: docker buildx build --platform linux/amd64,arm64│    │
│  │ - Coordinates via BuildKit                              │    │
│  │ - Uses /etc/buildkit/buildkitd.toml configuration       │    │
│  └────────┬────────────────────────────────────────────────┘    │
│           │                                                      │
│           ├─→ ser5.internal: Build AMD64 (native, fast!)        │
│           └─→ opi01.internal: Build ARM64 (native, fast!)       │
│                                                                  │
│  Result: Both builds run in parallel, ~2x faster than serial    │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Scenario 2: Local Development (calypso)                        │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ calypso (laptop)                                        │    │
│  │ - Runs: docker buildx build --platform linux/amd64,arm64│    │
│  │ - Uses multi-node buildx instance "avalanche-multi"    │    │
│  └────────┬────────────────────────────────────────────────┘    │
│           │                                                      │
│           ├─→ ser5.internal: Build AMD64 via SSH                │
│           └─→ opi01.internal: Build ARM64 via SSH               │
│                                                                  │
│  Result: Build multi-arch from laptop without emulation         │
└──────────────────────────────────────────────────────────────────┘
```

## Current State: eagle's BuildKit Configuration

Eagle already has BuildKit configured for Forgejo Actions:

**Location**: `nixos/hosts/eagle/forgejo/forgejo-runner.nix:27-37`

```nix
environment.etc."buildkit/buildkitd.toml".text = ''
  # Disable Container Device Interface (CDI) to prevent GPU detection
  # Eagle has no GPU, and CDI auto-detection causes container start failures
  [cdi]
    disabled = true

  [registry."forge.internal"]
    http = true
    insecure = true
    ca=["/etc/ssl/certs/ca-certificates.crt"]
'';
```

This configuration:
- Disables CDI to prevent GPU detection failures on eagle
- Allows insecure HTTP access to local Forgejo registry
- Configures CA certificates for private step-ca

## Part 1: BuildKit Remote Workers (Recommended)

### What It Solves
- Automatic architecture routing (AMD64 → ser5, ARM64 → opi nodes)
- No QEMU emulation (native builds on each architecture)
- System-wide configuration (works for all Docker/BuildKit operations)
- Reuses existing Nix distributed build infrastructure

### Configuration

#### On eagle (Forgejo Runner Host)

Extend the existing `buildkitd.toml` configuration:

```nix
# nixos/hosts/eagle/forgejo/forgejo-runner.nix

environment.etc."buildkit/buildkitd.toml".text = ''
  # Disable Container Device Interface (CDI) to prevent GPU detection
  # Eagle has no GPU, and CDI auto-detection causes container start failures
  [cdi]
    disabled = true

  [registry."forge.internal"]
    http = true
    insecure = true
    ca=["/etc/ssl/certs/ca-certificates.crt"]

  # ── Remote Builder Configuration ──────────────────────────────
  # Routes builds to appropriate architecture hosts automatically
  # Uses same SSH infrastructure as Nix distributed builds

  # SER5 MAX - AMD64 Builder
  [[worker.oci]]
    platforms = ["linux/amd64"]
    max-parallelism = 8  # SER5 has 8 cores

    [worker.oci.ssh]
      address = "ssh://nix-builder@ser5.internal"
      # SSH key must be accessible by gitea-runner user
      identity = "/var/lib/gitea-runner/.ssh/id_nix_builder"

  # Orange Pi 5 Plus - ARM64 Builder
  [[worker.oci]]
    platforms = ["linux/arm64"]
    max-parallelism = 6  # opi nodes have 8 cores, leave headroom for K3s

    [worker.oci.ssh]
      address = "ssh://nix-builder@opi01.internal"
      identity = "/var/lib/gitea-runner/.ssh/id_nix_builder"

  # Local fallback - ARM64 (eagle itself)
  # Useful if remote builders are offline
  [[worker.oci]]
    platforms = ["linux/arm64"]
    max-parallelism = 4  # eagle is ARM64, can build locally as fallback
'';
```

#### SSH Key Setup for Forgejo Runners

Forgejo runners need SSH access to remote builders. Two approaches:

**Option A: Copy from root (Simple)**

```nix
# nixos/hosts/eagle/forgejo/forgejo-runner.nix

systemd.tmpfiles.rules = [
  # Create .ssh directory for gitea-runner user
  "d /var/lib/gitea-runner/.ssh 0700 gitea-runner gitea-runner"

  # Copy nix-builder SSH key (assumes already exists for Nix builds)
  # This runs at system activation, before runner starts
  "C /var/lib/gitea-runner/.ssh/id_nix_builder 0600 gitea-runner gitea-runner - /root/.ssh/id_nix_builder"
];
```

**Option B: Manage with SOPS (More Secure)**

```nix
# secrets/eagle/secrets.sops.yaml
# Add builder_ssh_private_key entry

# nixos/hosts/eagle/forgejo/forgejo-runner.nix
sops.secrets.builder_ssh_key = {
  owner = "gitea-runner";
  group = "gitea-runner";
  mode = "0600";
  path = "/var/lib/gitea-runner/.ssh/id_nix_builder";
  restartUnits = [ "gitea-runner-first.service" "gitea-runner-second.service" ];
};
```

**Option C: Shared Key (Recommended - Reuses Nix Infrastructure)**

Use the same SSH key as Nix distributed builds:

```bash
# On calypso (during initial setup)
# Generate key if not already exists
ssh-keygen -t ed25519 -f ~/.ssh/id_nix_builder -C "builder-key"

# Copy public key to eagle
ssh-copy-id -i ~/.ssh/id_nix_builder eagle.internal

# On eagle, copy to gitea-runner location
sudo mkdir -p /var/lib/gitea-runner/.ssh
sudo cp ~/.ssh/id_nix_builder /var/lib/gitea-runner/.ssh/
sudo chown -R gitea-runner:gitea-runner /var/lib/gitea-runner/.ssh
sudo chmod 600 /var/lib/gitea-runner/.ssh/id_nix_builder
```

#### On Remote Builders (ser5, opi01)

**Create builder profile** for reuse across Nix and Docker builds:

```nix
# nixos/profiles/role-builder.nix (NEW FILE)
{ config, pkgs, ... }:
{
  # Shared builder user for both Nix and Docker remote builds
  users.users.nix-builder = {
    isSystemUser = true;
    group = "nix-builder";
    createHome = true;
    home = "/var/lib/nix-builder";
    openssh.authorizedKeys.keys = [
      # Public key from calypso (for Nix builds)
      "ssh-ed25519 AAAAC3Nza... calypso-nix-builder"
      # Public key from eagle (for Docker builds via Forgejo runners)
      "ssh-ed25519 AAAAC3Nza... eagle-builder"
    ];
  };

  users.groups.nix-builder = {};

  # Trust nix-builder for Nix operations
  nix.settings.trusted-users = [ "nix-builder" ];

  # Enable Docker for BuildKit remote builds
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Allow nix-builder to use Docker (required for BuildKit)
  users.users.nix-builder.extraGroups = [ "docker" ];

  # Optional: Run BuildKit daemon for advanced features
  # (Not required if using Docker's embedded BuildKit)
  # virtualisation.buildkitd = {
  #   enable = true;
  #   settings = {
  #     registry."forge.internal" = {
  #       http = true;
  #       insecure = true;
  #       ca = [ "/etc/ssl/certs/ca-certificates.crt" ];
  #     };
  #   };
  # };
}
```

**Apply profile to builder hosts:**

```nix
# nixos/hosts/ser5/default.nix
{ config, ... }:
{
  imports = [
    ../../profiles/role-server.nix
    ../../profiles/role-builder.nix  # NEW
  ];
  # ... rest of config
}

# nixos/hosts/opi01/default.nix
{ config, ... }:
{
  imports = [
    ../../profiles/hw-orange-pi-5-plus.nix
    ../../profiles/role-k3s-controller.nix
    ../../profiles/role-builder.nix  # NEW
  ];
  # ... rest of config
}
```

#### Testing Remote Builder Connectivity

```bash
# From eagle, test SSH as gitea-runner user
sudo -u gitea-runner ssh -i /var/lib/gitea-runner/.ssh/id_nix_builder nix-builder@ser5.internal

# Verify Docker access
sudo -u gitea-runner ssh -i /var/lib/gitea-runner/.ssh/id_nix_builder nix-builder@ser5.internal docker info

# Test BuildKit connectivity
sudo -u gitea-runner ssh -i /var/lib/gitea-runner/.ssh/id_nix_builder nix-builder@opi01.internal docker buildx version
```

## Part 2: Docker Buildx Multi-Node (Alternative)

### What It Solves
- Runtime builder configuration (more flexible than buildkitd.toml)
- Per-instance customization (different builders for different projects)
- Works from development machines (calypso) without system config changes

### Configuration

#### On Development Machine (calypso)

```bash
# Create multi-arch builder instance
docker buildx create \
  --name avalanche-multi \
  --driver docker-container \
  --bootstrap

# Add SER5 MAX as AMD64 builder
docker buildx create \
  --name avalanche-multi \
  --append \
  --platform linux/amd64 \
  --node ser5-amd64 \
  ssh://nix-builder@ser5.internal

# Add Orange Pi as ARM64 builder
docker buildx create \
  --name avalanche-multi \
  --append \
  --platform linux/arm64 \
  --node opi-arm64 \
  ssh://nix-builder@opi01.internal

# Set as default builder
docker buildx use avalanche-multi

# Verify configuration
docker buildx inspect avalanche-multi
```

**Expected output:**
```
Name:          avalanche-multi
Driver:        docker-container
Last Activity: 2025-12-30 12:34:56 +0000 UTC

Nodes:
Name:           ser5-amd64
Endpoint:       ssh://nix-builder@ser5.internal
Status:         running
Platforms:      linux/amd64*, linux/amd64/v2, linux/amd64/v3

Name:           opi-arm64
Endpoint:       ssh://nix-builder@opi01.internal
Status:         running
Platforms:      linux/arm64*, linux/arm/v8
```

#### Persistent Configuration for Forgejo Runners

If using Buildx approach instead of buildkitd.toml, configure builder during system startup:

```nix
# nixos/hosts/eagle/forgejo/forgejo-runner.nix

systemd.services.gitea-runner-buildx-setup = {
  description = "Configure Docker Buildx for multi-arch remote builds";
  after = [ "docker.service" ];
  before = [ "gitea-runner-first.service" "gitea-runner-second.service" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    User = "gitea-runner";
    WorkingDirectory = "/var/lib/gitea-runner";
  };

  script = ''
    export HOME=/var/lib/gitea-runner
    export DOCKER_CONFIG=$HOME/.docker

    # Remove old builder if exists (ensures clean state)
    ${pkgs.docker}/bin/docker buildx rm avalanche-multi || true

    # Create multi-arch builder
    ${pkgs.docker}/bin/docker buildx create \
      --name avalanche-multi \
      --driver docker-container \
      --bootstrap

    # Add SER5 MAX (AMD64 builder)
    ${pkgs.docker}/bin/docker buildx create \
      --name avalanche-multi \
      --append \
      --platform linux/amd64 \
      --node ser5-amd64 \
      ssh://nix-builder@ser5.internal

    # Add Orange Pi (ARM64 builder)
    ${pkgs.docker}/bin/docker buildx create \
      --name avalanche-multi \
      --append \
      --platform linux/arm64 \
      --node opi-arm64 \
      ssh://nix-builder@opi01.internal

    # Set as default
    ${pkgs.docker}/bin/docker buildx use avalanche-multi

    echo "Buildx multi-arch builder configured successfully"
  '';
};
```

## Usage Examples

### Scenario 1: Forgejo Actions Workflow (Multi-Arch Build)

```yaml
# .forgejo/workflows/build-multiarch.yaml
name: Build Multi-Architecture Container

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: native  # Runs on eagle
    steps:
      - uses: actions/checkout@v4

      - name: Login to Forgejo Registry
        run: echo "${{ secrets.FORGEJO_TOKEN }}" | docker login forge.internal -u nemo --password-stdin

      - name: Build and push multi-arch image
        run: |
          docker buildx build \
            --platform linux/amd64,linux/arm64 \
            -t forge.internal/${{ github.repository }}:${{ github.sha }} \
            -t forge.internal/${{ github.repository }}:latest \
            --cache-from type=registry,ref=forge.internal/${{ github.repository }}:buildcache \
            --cache-to type=registry,ref=forge.internal/${{ github.repository }}:buildcache,mode=max \
            --push \
            .
```

**What happens:**
1. Workflow triggers on eagle (ARM64 host)
2. BuildKit sees `--platform linux/amd64,linux/arm64`
3. Reads `/etc/buildkit/buildkitd.toml` configuration
4. Routes AMD64 build to `ser5.internal` via SSH
5. Routes ARM64 build to `opi01.internal` via SSH
6. **Both builds run in parallel** (2x faster than serial)
7. Results pushed to Forgejo registry as manifest list

### Scenario 2: Local Multi-Arch Build from calypso

```bash
# On calypso (development machine)
cd ~/my-project

# Build for both architectures (uses remote builders)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t forge.internal/nemo/myapp:latest \
  --push \
  .

# Result: AMD64 built on ser5, ARM64 built on opi01, both pushed to registry
```

### Scenario 3: Single Architecture Build (Fast Testing)

```bash
# Build only ARM64 (uses opi01 builder)
docker buildx build \
  --platform linux/arm64 \
  -t myapp:test-arm64 \
  --load \
  .

# Build only AMD64 (uses ser5 builder)
docker buildx build \
  --platform linux/amd64 \
  -t myapp:test-amd64 \
  --load \
  .
```

### Scenario 4: Registry Cache for Faster Rebuilds

```bash
# First build: populates cache
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --cache-from type=registry,ref=forge.internal/nemo/myapp:buildcache \
  --cache-to type=registry,ref=forge.internal/nemo/myapp:buildcache,mode=max \
  -t forge.internal/nemo/myapp:v1.0.0 \
  --push \
  .

# Second build: reuses cached layers (much faster!)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --cache-from type=registry,ref=forge.internal/nemo/myapp:buildcache \
  --cache-to type=registry,ref=forge.internal/nemo/myapp:buildcache,mode=max \
  -t forge.internal/nemo/myapp:v1.0.1 \
  --push \
  .
```

**Cache modes:**
- `mode=min`: Only cache final image layers (smaller, less reuse)
- `mode=max`: Cache all intermediate layers (larger, maximum reuse) - **Recommended**

### Scenario 5: S3 Cache Backend (Using Garage)

```bash
# Configure AWS credentials for Garage
export AWS_ACCESS_KEY_ID=your-garage-key
export AWS_SECRET_ACCESS_KEY=your-garage-secret

# Build with S3 cache
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --cache-from type=s3,region=garage,bucket=docker-buildcache,endpoint_url=http://possum.internal:3900 \
  --cache-to type=s3,region=garage,bucket=docker-buildcache,endpoint_url=http://possum.internal:3900,mode=max \
  -t forge.internal/nemo/myapp:latest \
  --push \
  .
```

**Advantages of S3 cache:**
- Shared across all builders (eagle, calypso, CI/CD)
- No registry pollution (cache stored separately)
- Better for large caches (can exceed registry limits)

## Verification

### Check Remote Builders Are Used

```bash
# Build with verbose output
docker buildx build --progress=plain --platform linux/amd64 -t test:amd64 . 2>&1 | grep -i ssh

# Expected output:
# => [internal] connecting to ssh://nix-builder@ser5.internal
```

### Verify Multi-Arch Manifest

```bash
# Inspect multi-arch image
docker buildx imagetools inspect forge.internal/nemo/myapp:latest

# Expected output:
# Name:      forge.internal/nemo/myapp:latest
# MediaType: application/vnd.docker.distribution.manifest.list.v2+json
# Digest:    sha256:abc123...
#
# Manifests:
#   Name:      forge.internal/nemo/myapp:latest@sha256:def456...
#   MediaType: application/vnd.docker.distribution.manifest.v2+json
#   Platform:  linux/amd64
#
#   Name:      forge.internal/nemo/myapp:latest@sha256:789abc...
#   MediaType: application/vnd.docker.distribution.manifest.v2+json
#   Platform:  linux/arm64
```

### Test Image on Different Architectures

```bash
# On calypso (AMD64)
docker run --rm forge.internal/nemo/myapp:latest uname -m
# Output: x86_64

# On opi01 (ARM64)
docker run --rm forge.internal/nemo/myapp:latest uname -m
# Output: aarch64

# Docker automatically pulls the correct architecture variant
```

### Monitor Build Performance

```bash
# Time single-arch build
time docker buildx build --platform linux/amd64 -t test:amd64 .

# Time multi-arch build (should be ~same as single, not 2x)
time docker buildx build --platform linux/amd64,linux/arm64 -t test:multi .

# With parallel remote builders, multi-arch should only be slightly slower
```

## Troubleshooting

### Builds Not Using Remote Builders

**Symptom**: Builds still use QEMU emulation (slow)

**Check**:
```bash
# Verify buildkitd.toml is loaded
docker buildx inspect --bootstrap

# Check for remote workers
docker buildx inspect | grep -A5 "Endpoint:"

# Should show:
# Endpoint: ssh://nix-builder@ser5.internal
# Endpoint: ssh://nix-builder@opi01.internal
```

**Common fixes**:
1. SSH key not accessible: Check `/var/lib/gitea-runner/.ssh/id_nix_builder` exists and has correct permissions
2. Remote builder offline: Test `ssh nix-builder@ser5.internal`
3. Docker not running on remote: Check `ssh nix-builder@ser5.internal docker info`
4. Wrong platform specified: Verify `platforms = ["linux/amd64"]` matches builder architecture

### SSH Connection Failures

**Symptom**: `error: failed to solve: ssh://nix-builder@ser5.internal: connection refused`

**Debug**:
```bash
# Test SSH manually as gitea-runner user
sudo -u gitea-runner ssh -i /var/lib/gitea-runner/.ssh/id_nix_builder -v nix-builder@ser5.internal

# Common issues:
# - Key not in authorized_keys on remote
# - SSH service not running on remote
# - Firewall blocking port 22
# - Tailscale not connected
```

**Fix**:
```bash
# On remote builder (ser5/opi01)
sudo systemctl status sshd
sudo journalctl -u sshd -n 50

# Check authorized_keys
cat /var/lib/nix-builder/.ssh/authorized_keys

# Test from eagle
ssh -i /var/lib/gitea-runner/.ssh/id_nix_builder nix-builder@ser5.internal echo "success"
```

### BuildKit Cache Not Being Used

**Symptom**: Every build is slow, no cache reuse

**Check**:
```bash
# Inspect cache
docker buildx du --verbose

# Check if cache exists in registry
curl -s http://forge.internal/v2/nemo/myapp/tags/list | jq .

# Verify cache backend is accessible
# For registry cache:
docker pull forge.internal/nemo/myapp:buildcache

# For S3 cache:
curl http://possum.internal:3900/docker-buildcache/
```

**Common fixes**:
1. Cache mode not specified: Use `--cache-to type=registry,ref=...,mode=max`
2. Cache reference wrong: Ensure `--cache-from` and `--cache-to` use same `ref=`
3. Registry credentials missing: Check `docker login forge.internal`
4. S3 credentials wrong: Verify `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

### Permission Denied on Remote Builder

**Symptom**: `permission denied while trying to connect to the Docker daemon socket`

**Fix**:
```bash
# On remote builder, add nix-builder to docker group
sudo usermod -aG docker nix-builder

# Verify
ssh nix-builder@ser5.internal groups
# Should show: nix-builder docker

# Reboot or restart Docker service
ssh ser5.internal sudo systemctl restart docker
```

### Forgejo Runner Can't Find buildkitd.toml

**Symptom**: Runners don't use remote builders configured in buildkitd.toml

**Check**:
```bash
# Verify file exists and has correct permissions
ssh eagle.internal ls -la /etc/buildkit/buildkitd.toml

# Check runner environment
ssh eagle.internal "sudo -u gitea-runner env | grep BUILDKIT"
```

**Fix**:
```bash
# Rebuild eagle configuration
just nix deploy eagle

# Restart runners to pick up new config
ssh eagle.internal "sudo systemctl restart gitea-runner-first.service gitea-runner-second.service"

# Check logs for buildkit config loading
ssh eagle.internal "journalctl -u gitea-runner-first.service -n 100 | grep -i buildkit"
```

## Performance Expectations

### Current State (No Distributed Builds)

```
Multi-arch build on eagle (ARM64 host):
├─ linux/arm64: 5 min (native on eagle)
└─ linux/amd64: 25 min (QEMU emulation on eagle)
────────────────────────────────────────
Total:          30 min (sequential)
```

### With Distributed Builds

```
Multi-arch build on eagle (with remote builders):
├─ linux/arm64: 5 min (delegated to opi01, native)
└─ linux/amd64: 4 min (delegated to ser5, native, parallel)
────────────────────────────────────────
Total:          5 min (86% time savings!)
```

### Typical Build Times by Architecture

| Build Type | Native | QEMU Emulation | Remote Builder |
|------------|--------|----------------|----------------|
| Simple Node.js app (ARM64) | 2 min | 8 min | 2 min |
| Simple Node.js app (AMD64) | 1.5 min | - | 1.5 min |
| Complex Rust app (ARM64) | 15 min | 60+ min | 15 min |
| Complex Rust app (AMD64) | 8 min | - | 8 min |
| Multi-arch (sequential) | 23 min | 68 min | 23 min |
| Multi-arch (parallel builders) | - | - | **15 min** ✨ |

**Key insight**: With parallel remote builders, multi-arch build time ≈ max(arm64_time, amd64_time), not sum!

## Comparison: buildkitd.toml vs Buildx Multi-Node

| Feature | buildkitd.toml | Buildx Multi-Node |
|---------|----------------|-------------------|
| **Scope** | System-wide | Per-builder instance |
| **Configuration** | Static file in /etc | Runtime CLI commands |
| **Forgejo Actions** | Automatic | Requires setup script |
| **Persistence** | Survives reboots | Needs one-time setup |
| **Development** | Works from any host | Configure on each machine |
| **Flexibility** | Less (one config) | More (multiple builders) |
| **Debugging** | Harder (systemd logs) | Easier (docker buildx inspect) |
| **Recommended for** | Production (eagle) | Development (calypso) |

## Integration with Existing Infrastructure

### Reuses Nix Distributed Build Components

✅ **Same SSH keys**: Use `/var/lib/gitea-runner/.ssh/id_nix_builder` for both Nix and Docker builds

✅ **Same builder hosts**: ser5 and opi01 act as builders for both Nix and Docker

✅ **Same user**: `nix-builder` user handles both Nix and Docker build requests

✅ **Same network**: All communication over Tailscale (secure, encrypted)

### Complements Existing Forgejo Runner Setup

**Existing configuration** (from `forgejo-runner-upgrade-plan.md`):
- Two runners: `first` and `second`
- Labels: `native:host` and `docker:docker://node:24-bookworm`
- BuildKit configuration at `/etc/buildkit/buildkitd.toml` ✅ (already in place!)
- Docker autoPrune enabled ✅

**New capabilities added**:
- Remote builder routing (AMD64 → ser5, ARM64 → opi nodes)
- Parallel multi-arch builds
- No QEMU emulation overhead

**No breaking changes**:
- Existing workflows continue to work
- `--platform` flag is optional (defaults to host architecture)
- Fallback to local builds if remote unavailable

## Security Considerations

**Trust Model:**
- Remote builders are **trusted** (can execute arbitrary build instructions)
- Only add builders you control
- SSH provides authentication and encryption
- Docker socket access grants full container control

**Network:**
- All SSH communication over Tailscale (encrypted mesh VPN)
- BuildKit uses SSH tunnels (no additional ports needed)
- Forgejo registry access via internal network only

**Hardening:**
- Dedicated `nix-builder` user (no sudo, limited permissions)
- SSH key-based auth only (no passwords)
- Docker socket access restricted to `docker` group
- Consider signing cache with registry trust (future enhancement)

**Secrets Management:**
- Registry credentials in Forgejo secrets (`${{ secrets.FORGEJO_TOKEN }}`)
- SSH private keys via SOPS or tmpfiles
- Never commit private keys to git

## Next Steps

### When SER5 MAX Arrives (2026-01-02)

1. **Deploy NixOS to SER5**:
   ```bash
   # Apply role-builder profile
   just nix deploy ser5
   ```

2. **Generate SSH keys on eagle** (if not already exists):
   ```bash
   ssh eagle.internal
   sudo -u gitea-runner ssh-keygen -t ed25519 -f /var/lib/gitea-runner/.ssh/id_nix_builder -C "eagle-builder"
   ```

3. **Add eagle's public key to SER5's authorized_keys**:
   ```bash
   # Get public key from eagle
   ssh eagle.internal sudo -u gitea-runner cat /var/lib/gitea-runner/.ssh/id_nix_builder.pub

   # Add to nixos/hosts/ser5/default.nix in role-builder profile
   ```

4. **Uncomment SER5 builder in buildkitd.toml**:
   ```nix
   # nixos/hosts/eagle/forgejo/forgejo-runner.nix
   # Remove comment from SER5 [[worker.oci]] section
   ```

5. **Deploy updated configuration**:
   ```bash
   just nix deploy eagle
   ```

6. **Test multi-arch build**:
   ```bash
   # From eagle or via Forgejo workflow
   docker buildx build --platform linux/amd64,linux/arm64 -t test:multi .
   ```

### For Development Machines (calypso)

1. **Create Buildx multi-node builder**:
   ```bash
   docker buildx create --name avalanche-multi --driver docker-container --bootstrap
   docker buildx create --name avalanche-multi --append --platform linux/amd64 --node ser5-amd64 ssh://nix-builder@ser5.internal
   docker buildx create --name avalanche-multi --append --platform linux/arm64 --node opi-arm64 ssh://nix-builder@opi01.internal
   docker buildx use avalanche-multi
   ```

2. **Build multi-arch from laptop**:
   ```bash
   docker buildx build --platform linux/amd64,linux/arm64 -t myapp:latest --push .
   ```

### Optional Enhancements

1. **S3 cache backend**: Use Garage on possum for shared build cache
2. **Cache cleanup automation**: Systemd timer to prune old cache entries
3. **Monitoring**: Grafana dashboard for build times, cache hit rate
4. **Registry mirror**: Configure BuildKit to use nixpkgs mirror as Docker proxy

## Related Documentation

- [Nix Distributed Builds](nix-distributed-builds.md) - Parallel Nix build system
- [Forgejo Runner Upgrade Plan](../plans/forgejo-runner-upgrade-plan.md) - Runner configuration details
- [GitHub Outage Mitigation](github-outage-mitigation.md) - Registry and mirror fallbacks
- CLAUDE.md - Infrastructure overview and Forgejo Actions usage

## References

- **Docker Buildx Documentation**: https://docs.docker.com/build/buildx/
- **BuildKit Configuration**: https://github.com/moby/buildkit/blob/master/docs/buildkitd.toml.md
- **Docker Build Cache**: https://docs.docker.com/build/cache/
- **Multi-Architecture Images**: https://docs.docker.com/build/building/multi-platform/
- **SSH Builders**: https://docs.docker.com/build/drivers/remote/

---

**Created**: 2025-12-30
**Last Updated**: 2025-12-30
**Status**: 📝 Ready for implementation when SER5 MAX arrives (2026-01-02)
