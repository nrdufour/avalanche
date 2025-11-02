# Justfile Migration

This document tracks the migration of the justfile from snowpea into avalanche.

## Migration Date

Completed: 2025-11-02

## What Was Migrated

### From Snowpea

Copied as-is from snowpea with only the header comment updated:

**Main Justfile (`justfile`)**
- Updated header: "SnowPea" → "Avalanche"
- Imports all sub-justfiles
- Default recipe lists all commands
- Lint and format commands

**Sub-Justfiles (`.justfiles/`)**

**nix.just** - NixOS deployment and management:
- `nix-update` - Update flake.lock
- `nix-check` - Run flake check
- `nix-list-hosts` - List all NixOS configurations
- `nix-deploy <host>` - Deploy to a single host
- `nix-deploy-all` - Deploy to all hosts (with confirmation)

**sops.just** - Secrets management:
- `sops-update` - Update keys for all .sops.yaml files

**sd.just** - SD card image management:
- `sd-build <host>` - Build SD card image for a host
- `sd-flash <host>` - Build and flash SD card image with rpi-imager

### From Home-Ops

Merged from home-ops with `k8s-` prefix for all commands:

**k8s.just** - Kubernetes cluster management:
- `k8s-get-kubeconfig` - Retrieve kubeconfig from cluster (default: opi01.internal)
- `k8s-bootstrap <cluster>` - Bootstrap Flux on a cluster (default: main)
  - Installs Prometheus Operator CRDs
  - Installs Flux
  - Applies gitea-access and sops-age secrets
  - Applies cluster kustomizations

### Main Justfile Updates

**Environment Variables:**
```just
kubernetes_dir := root_dir / "kubernetes"
export KUBECONFIG := kubernetes_dir / "kubernetes/main/kubeconfig"
export SOPS_AGE_KEY_FILE := env_var('HOME') / ".config/sops/age/keys.txt"
```

**Imports:**
```just
import '.justfiles/nix.just'
import '.justfiles/sops.just'
import '.justfiles/sd.just'
import '.justfiles/k8s.just'
```

### Development Environment

**default.nix** - Merged tools from snowpea and home-ops:
```nix
# Common tools
just, jq

# NixOS tools
statix, nixpkgs-fmt, nixos-rebuild

# Kubernetes tools
kubectl, kubectl-cnpg, fluxcd, kubernetes-helm,
yamllint, cmctl, argocd
```

## Usage Examples

### NixOS Commands

```bash
# List all available commands
just

# Check the flake
just nix-check

# List all hosts
just nix-list-hosts

# Deploy to a remote host
just nix-deploy eagle

# Deploy locally
just nix-switch calypso

# Update SOPS keys
just sops-update

# Build SD card image
just sd-build raccoon00

# Flash SD card
just sd-flash raccoon00
```

### Kubernetes Commands

```bash
# Get kubeconfig from cluster
just k8s-get-kubeconfig

# Bootstrap Flux on the main cluster
just k8s-bootstrap

# Bootstrap a specific cluster
just k8s-bootstrap production
```

## Network Assumptions

**NixOS Deployments:**
- Hosts are accessible via `<hostname>.internal` domain
- SSH access is configured
- Remote sudo is available

**Kubernetes:**
- K3s cluster accessible via kube-vip at 10.1.0.5
- Default kubeconfig retrieved from opi01.internal
- SOPS_AGE_KEY_FILE must exist at ~/.config/sops/age/keys.txt

## Design Decisions

**Unified Justfile:**
- Merged justfiles with clear prefixes (nix-, k8s-, sd-, sops-)
- Environment variables configured in main justfile
- All tools available via direnv + default.nix

**Command Naming:**
- NixOS commands: `nix-*` prefix
- Kubernetes commands: `k8s-*` prefix
- Secrets: `sops-*` prefix
- SD cards: `sd-*` prefix

## Notes

- Snowpea justfile recipes copied exactly with no modifications (except header)
- Home-ops justfile merged with `k8s-` prefix for all commands
- Added `nix-switch` command for local deployments
- Environment variables unified in main justfile

---

*Last updated: 2025-11-02*
