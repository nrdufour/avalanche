# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Avalanche is a unified infrastructure-as-code monorepo managing 17 NixOS hosts (ARM SBCs, x86 servers, and workstations) plus a Kubernetes cluster using GitOps. This consolidates configurations from previously separate repositories (snowy, snowpea, home-ops).

## Architecture

### Three-Layer Structure

1. **NixOS Layer** (`nixos/`): Declarative system configurations
   - `hosts/`: Per-machine configurations (calypso, eagle, mysecrets, opi01-03, raccoon00-05, etc.)
   - `profiles/`: Reusable configurations
     - `hw-*.nix`: Hardware-specific (RPi4, Orange Pi 5 Plus, Acer mini PC)
     - `role-*.nix`: Role-based (server, workstation, k3s-controller, k3s-worker)
     - `global.nix`: Applied to all machines
   - `personalities/`: Feature sets (base, development, ham, chat, backups, knowledge, laptop)
   - `modules/nixos/`: Custom NixOS modules
   - `lib/`: Helper functions (currently minimal)
   - `pkgs/`: Custom package definitions
   - `overlays/`: Nixpkgs overlays

2. **Kubernetes Layer** (`kubernetes/`): GitOps manifests for K3s cluster
   - `base/`: Application definitions organized by category
     - `apps/`: User applications (ai, cnpg-system, games, home-automation, irc, media, ml, self-hosted, tests)
     - `argocd/`: ArgoCD self-management
     - `components/`: Reusable components (volsync)
     - `infra/`: Infrastructure services (cert-manager, longhorn, network, observability, security, system)
   - `clusters/`: Cluster-specific configurations
   - **Primary GitOps**: ArgoCD only

3. **Cloud Layer** (`cloud/`): Future cloud infrastructure
   - `nixos/`: NixOS-based VPS configs
   - `terraform/`: Non-NixOS cloud resources

### Configuration System

**NixOS hosts are built using `mkNixosConfig`** (flake.nix:59-95):
- Combines `baseModules` (sops, global profile, custom modules, host config)
- Applies `hardwareModules` (hardware quirks, SD card images)
- Applies `profileModules` (roles like server/workstation)
- Sets `stateVersion` (default: 23.11; calypso: 24.05; routy/cardinal: 25.05)

**Personalities are additive feature sets** imported by individual hosts:
- Example: calypso imports ham, chat, backups, knowledge personalities (nixos/hosts/calypso/default.nix:8-11)
- Base personalities are imported through role profiles

## Common Commands

### Development Environment
```bash
direnv allow                    # Activate direnv (sets KUBECONFIG, SOPS_AGE_KEY_FILE)
just                            # List all available commands
just nix                        # Shows nix module commands
just k8s                        # Shows k8s module commands
just nix check                  # Check flake validity
just lint                       # Lint Nix files
just format                     # Format Nix files
```

### NixOS Management
```bash
just nix list-hosts             # List all NixOS hosts
just nix deploy <hostname>      # Deploy to remote host
just nix switch                 # Deploy locally (current machine only)
just nix deploy-all             # Deploy to all hosts (with confirmation)
just nix update                 # Update flake inputs
just sd build <hostname>        # Build SD card image (ARM hosts)
just sd flash <hostname>        # Build and flash SD card
```

### Secrets Management (SOPS + Age)
```bash
just sops update                # Update SOPS keys for all secrets
sops secrets/<hostname>/secrets.sops.yaml  # Decrypt a secret file
```

**SOPS Configuration**: `.sops.yaml` defines encryption rules by path regex. Each host has a dedicated age key. Admin keys can decrypt all secrets.

### Kubernetes Management
```bash
just k8s get-kubeconfig         # Get kubeconfig from cluster (kube-vip VIP: 10.1.0.5)
just k8s bootstrap              # Bootstrap Flux on cluster
just k8s force-es-refresh       # Force ExternalSecrets refresh
just k8s check-es-status        # Check ExternalSecrets status
argocd app list                 # Check sync status
```

### Forgejo CLI (fj)

The `fj` command provides programmatic access to `forge.internal`. Authentication is pre-configured for `nemo@forge.internal`.

```bash
# Common commands
fj issue search                 # List open issues
fj issue create "Title" --body "Description"
fj pr search                    # List open PRs
fj pr create "Title"            # Create PR
fj pr merge 42                  # Merge PR
fj actions tasks                # List recent CI runs
```

Use `fj <subcommand> --help` for full options. Commands auto-detect repo from git remote.

### Sentinel (Gateway Dashboard)

Web-based gateway management dashboard for routy (network services, DHCP, firewall, connections).

- **Repository**: `forge.internal/nemo/sentinel` (separate repo)
- **Access**: `https://sentinel.internal` (via Tailscale)
- **NixOS package**: `nixos/pkgs/sentinel/default.nix` fetches from external repo

## Infrastructure Details

### NixOS Hosts (17 total)
- **Workstation**: calypso (ASUS ROG Strix)
- **Infrastructure**: mysecrets (step-ca, Vaultwarden, Kanidm), eagle (Forgejo, CI/CD), possum (Garage S3, backups)
- **x86 Servers**: beacon, routy (main gateway), cardinal, sparrow01
- **K3s Controllers**: opi01-03 (Orange Pi 5 Plus, aarch64, **NPU-enabled**)
- **K3s Workers**: raccoon00-05 (Raspberry Pi 4, aarch64)

### Key Technologies
- **Deployment**: nixos-rebuild over SSH to `<hostname>.internal` (Tailscale)
- **Secrets**: SOPS with Age encryption (keys in `~/.config/sops/age/keys.txt`)
- **Network**: Tailscale mesh VPN (remote access), Gluetun VPN proxy (egress for K8s workloads), kube-vip for K8s HA (VIP: 10.1.0.5)
- **Identity**: Kanidm at `https://auth.internal` (users: `username@auth.internal`)
- **GitOps**: ArgoCD only
- **Nixpkgs Mirror**: `forge.internal/Mirrors/nixpkgs` (fallback for GitHub outages)
- **Storage**: Longhorn (K8s), Garage S3 (object storage)
- **AI/ML**: Orange Pi 5 Plus NPU (mainline kernel + Mesa Teflon TensorFlow Lite)

## Documentation

See `docs/README.md` for the full documentation index. Key areas:
- `docs/architecture/` - System design (network, NPU, surveillance)
- `docs/guides/` - How-to guides (identity, upgrades, GitHub outage mitigation)
- `docs/troubleshooting/` - Known issues and workarounds

## Identity Management (Kanidm)

- **Location**: mysecrets host at `https://auth.internal`
- **Admin accounts**: `admin` (basic), `idm_admin` (full identity management)
- **Documentation**: `docs/guides/identity/kanidm-user-management.md`

All administration is CLI-based via `kanidm` command on mysecrets.internal.

## Important Patterns

### Adding a New NixOS Host
1. Create directory: `nixos/hosts/<hostname>/`
2. Add `default.nix` and `hardware-configuration.nix`
3. Add entry in `flake.nix` nixosConfigurations using `mkNixosConfig`
4. Generate age key on host: `nix-shell -p age --run "age-keygen"`
5. Add age key to `.sops.yaml` creation_rules
6. Create secrets directory: `secrets/<hostname>/`

### Modifying Secrets
- Secrets are per-host or shared (common-local-restic, common-remote-restic, k3s-worker)
- Always run `just sops-update` after modifying `.sops.yaml` to re-encrypt
- SOPS keys are loaded in host configs via `sops.defaultSopsFile`

### Deployment Flow
- Push to git → Forgejo webhook → AutoUpgrade pulls and rebuilds (for NixOS)
- Push to git → ArgoCD syncs (for Kubernetes)
- Manual: `just nix-deploy <hostname>` builds locally, deploys remotely

### Testing Changes
- Build locally first: `nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel`
- Check flake: `just nix-check` or `nix flake check`
- Lint: `just lint` (uses statix)
- Format: `just format` (uses nixpkgs-fmt)

## Directory Conventions

- **NixOS**:
  - Host-specific config: `nixos/hosts/<hostname>/default.nix`
  - Shared profiles: `nixos/profiles/` (imported via profileModules)
  - Feature bundles: `nixos/personalities/` (imported directly in host configs)
  - Secrets: `secrets/<hostname>/` (encrypted with SOPS)
- **Kubernetes**:
  - Apps: `kubernetes/base/apps/<category>/<app>/`
  - Infrastructure: `kubernetes/base/infra/<category>/<service>/`
  - ArgoCD apps: `kubernetes/base/<category>/<name>-app.yaml`
- **External Repositories**:
  - `forge.internal/nemo/sentinel` - Gateway management dashboard (Go)
- **Documentation**:
  - Architecture: `docs/architecture/<domain>/`
  - Guides: `docs/guides/<topic>/`
  - Plans: `docs/plans/`
  - Troubleshooting: `docs/troubleshooting/`

## ArgoCD Notes

### Config Management Plugin (CMP) - kustomize-envsubst

A custom CMP plugin enables Flux-like variable substitution in Kustomize manifests. Variables are passed via ArgoCD Application `plugin.env` and substituted using `envsubst`.

**Usage in Application:**
```yaml
spec:
  source:
    plugin:
      name: kustomize-envsubst
      env:
        - name: APP
          value: myapp
        - name: VOLSYNC_CAPACITY
          value: 5Gi
```

Variables become `ARGOCD_ENV_<name>` (e.g., `${ARGOCD_ENV_APP}`) in templates.

**CRITICAL: Hard Refresh Required**
When modifying an ArgoCD Application to add or change CMP plugin configuration, ArgoCD caches the old manifests. You MUST run a hard refresh to regenerate manifests with the new plugin:
```bash
argocd app get <app-name> --hard-refresh
```

**CRITICAL: Never Use Auto-Discovery with envsubst**
Do NOT add `discover` settings to the CMP plugin configuration. Auto-discovery causes ALL apps with kustomization.yaml to be processed through `envsubst`, which strips ALL `$variable` references from manifests (breaks multi-source helm valueFiles, shell scripts in ConfigMaps, Redis HA, etc.). This caused a major incident (Feb 2026). The plugin must ONLY be used when explicitly specified in an Application's `plugin.name` field.

### VolSync Component (volsync-v2)

Reusable Kustomize component for backup/restore at `kubernetes/base/components/volsync-v2/`.

**What it provides:** PVC with dataSourceRef, ReplicationSource/Destination (S3 backup/restore), ExternalSecret (S3 credentials), ConfigMap with Ptinem Root CA.

**Required env vars (in ArgoCD Application):**
- `APP` - Application name (used in resource names and S3 path)
- `VOLSYNC_CAPACITY` - PVC size (e.g., "2Gi")
- `VOLSYNC_BITWARDEN_KEY` - Bitwarden item UUID for S3 credentials

**Optional env vars:** `VOLSYNC_STORAGECLASS` (default: longhorn), `VOLSYNC_ACCESSMODE` (default: ReadWriteOnce), `VOLSYNC_CACHE_CAPACITY` (default: 2Gi), `VOLSYNC_SCHEDULE` (default: "0 * * * *"), `VOLSYNC_UID`/`VOLSYNC_GID` (default: 1000)

**Minimal app kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
components:
  - ../../../components/volsync-v2
patches:
  # For existing apps with data - prevent restore on sync
  - target:
      kind: PersistentVolumeClaim
      name: .*
    patch: |
      - op: remove
        path: /spec/dataSourceRef
```

**Notes:**
- CA Certificate is included in component; no per-app patches needed
- For existing apps with data, the dataSourceRef patch prevents restore on sync
- `cleanupTempPVC: false` is set for Longhorn compatibility
- **Apps using volsync-v2:** esphome, mqtt, archivebox, kanboard

### Multi-Source Applications with CMP

Multi-source ArgoCD Applications (using `sources:` array) work with CMP plugins. Each source can have its own plugin configuration.

## Critical Notes

- **Do NOT** commit unencrypted secrets
- **Do NOT** modify stateVersion on existing systems (it's a NixOS compatibility marker, not a version to upgrade)
- **Always** test NixOS changes locally before `nix-deploy-all`
- **Remember** hosts are accessed via `<hostname>.internal` (Tailscale DNS)
- Kubernetes kubeconfig uses kube-vip VIP (10.1.0.5), not individual controller IPs

### Network Architecture Notes

#### Android 16 & DSCP Marking Fix (routy)
routy applies a global DSCP clearing rule (`nixos/hosts/routy/android16-fix.nix`) that resets all DSCP markings to cs0 on the FORWARD chain. This resolves Android 16 strict packet validation issues. If you later implement QoS policies that depend on DSCP, this rule should be reconsidered.

#### Tailscale vs Gluetun Separation
- **Tailscale**: Remote access to home network (mesh VPN, subnet routing via routy)
- **Gluetun**: VPN egress for containerized workloads (qbittorrent sidecar, marmithon IRC bot)
- **Do NOT use Tailscale exit nodes for K8s pods** - use Gluetun instead

See `docs/architecture/network/network-architecture-migration.md` for details.

### NPU (Neural Processing Unit) Integration

- **Nodes**: opi01-03 (Orange Pi 5 Plus with RK3588 SoC, 6 TOPS NPU)
- **Stack**: Mainline Linux 6.18+ `rocket` driver + Mesa 25.3+ Teflon TensorFlow Lite (NOT vendor RKNN stack)
- **Service**: `kubernetes/base/apps/ml/npu-inference/` - HTTP inference on port 8080
- **Models**: Standard `.tflite` format (NOT `.rknn`)

See `docs/architecture/npu/rknn-npu-integration-plan.md` for details.

### Surveillance System (Planned)

Design phase complete. Plan: Frigate NVR on possum with USB Coral TPU, Reolink PoE cameras. See `docs/architecture/surveillance/camera-setup-plan.md`.
