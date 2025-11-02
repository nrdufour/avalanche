# Kubernetes (home-ops) Migration

This document tracks the migration of Kubernetes manifests from home-ops into avalanche.

## Migration Date

Completed: 2025-11-02

## What Was Migrated

### Complete Directory Structure

Copied entire home-ops content to `kubernetes/`:

```
kubernetes/
├── base/                           # ArgoCD applications
│   ├── apps/                       # Application definitions
│   │   ├── cnpg-system/           # PostgreSQL operator
│   │   ├── home-automation/       # Grafana, InfluxDB2, RTL433, etc.
│   │   ├── irc/                   # Marmithon IRC bot
│   │   ├── media/                 # Media stack (arr apps)
│   │   ├── self-hosted/           # Miniflux, SearXNG, Mealie, etc.
│   │   └── tests/                 # Test applications
│   ├── infra/                     # Infrastructure applications
│   │   ├── cert-manager/          # TLS certificates
│   │   ├── longhorn-system/       # Distributed storage
│   │   ├── network/               # Ingress, DNS, CoreDNS
│   │   ├── observability/         # Prometheus stack
│   │   ├── security/              # External Secrets, Bitwarden
│   │   └── system/                # Kyverno, NFD, Kured, etc.
│   ├── argocd/                    # ArgoCD self-management
│   ├── components/                # Reusable components (volsync)
│   └── top/                       # Top-level app-of-apps
├── clusters/main/                 # Cluster-specific configs
│   ├── app/                       # Main cluster application
│   └── cluster.yaml               # Cluster bootstrap app
├── kubernetes/main/               # Flux manifests (to migrate)
│   ├── apps/                      # Flux Kustomizations
│   ├── flux/                      # Flux system config
│   └── bootstrap/                 # Bootstrap configs
├── bin/                           # Helper scripts
├── bootstrap/                     # Bootstrap manifests
└── docs/                          # Documentation
```

### Files Migrated

**Total:** 582 files

**ArgoCD Applications:** 43 application manifests
- Infrastructure: 17 apps
- Applications: 26 apps

**Flux Manifests:** 90+ Kustomization objects
- Apps: home-automation, self-hosted, media, ai, irc
- Infrastructure: Still in Flux (to be migrated)

## Path and URL Corrections

All paths and repository URLs were updated to reflect the new monorepo structure.

### ArgoCD Applications

**Path Updates:**
```yaml
# Before
path: base/apps/self-hosted/miniflux

# After
path: kubernetes/base/apps/self-hosted/miniflux
```

**Repository URL Updates:**
```yaml
# Before
repoURL: https://forge.internal/nemo/home-ops.git

# After
repoURL: https://forge.internal/nemo/avalanche.git
```

**Files Updated:** 43 ArgoCD Application manifests

### Flux GitRepository

Updated the single GitRepository object used by all Flux Kustomizations:

**Location:** `kubernetes/kubernetes/main/flux/config/cluster.yaml`

```yaml
# Before
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: home-ops-kubernetes
spec:
  url: ssh://forgejo@forge.internal/nemo/home-ops.git

# After
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: home-ops-kubernetes
spec:
  url: ssh://forgejo@forge.internal/nemo/avalanche.git
```

### Flux Kustomizations

**Path Updates:**
```yaml
# Before
path: ./kubernetes/main/apps/self-hosted/miniflux/app

# After
path: ./kubernetes/kubernetes/main/apps/self-hosted/miniflux/app
```

**Files Updated:** 90+ Flux Kustomization manifests

The extra `kubernetes/` prefix accounts for the new structure where the home-ops content is under `kubernetes/` in the avalanche repo.

## Justfile Integration

Merged home-ops justfile commands with `k8s-` prefix.

### Commands Added

**k8s-get-kubeconfig** - Retrieve kubeconfig from cluster
```bash
just k8s-get-kubeconfig              # Default: opi01.internal
just k8s-get-kubeconfig opi02.internal
```

**k8s-bootstrap** - Bootstrap Flux on cluster
```bash
just k8s-bootstrap                   # Default: main cluster
```

Steps performed by bootstrap:
1. Install Prometheus Operator CRDs (v0.80.0)
2. Install Flux via kustomize
3. Decrypt and apply gitea-access secret (SOPS)
4. Decrypt and apply sops-age secret (SOPS)
5. Apply cluster kustomizations

### Environment Variables

Added to main justfile:
```just
kubernetes_dir := root_dir / "kubernetes"
export KUBECONFIG := kubernetes_dir / "kubernetes/main/kubeconfig"
export SOPS_AGE_KEY_FILE := env_var('HOME') / ".config/sops/age/keys.txt"
```

## Development Tools

Merged Kubernetes tools into `default.nix`:

```nix
# Kubernetes tools
kubectl          # CLI for Kubernetes
kubectl-cnpg     # CloudNativePG plugin
fluxcd           # Flux CLI
kubernetes-helm  # Helm package manager
yamllint         # YAML linter
cmctl            # cert-manager CLI
argocd           # ArgoCD CLI
```

All tools available via `direnv` when in the repo.

## GitOps Architecture

### Current State

**ArgoCD (Active):**
- Infrastructure applications (cert-manager, ingress, storage, etc.)
- Self-hosted applications (Miniflux, SearXNG, Mealie, etc.)
- Home automation (Grafana, InfluxDB2, RTL433, etc.)
- Media stack (Radarr, Sonarr, qBittorrent, etc.)
- CNPG system (PostgreSQL operator)

**Flux (Legacy - To Migrate):**
- Remaining application manifests in `kubernetes/main/apps/`
- System configurations in `kubernetes/main/flux/`

### Migration Strategy

The home-ops cluster is in transition from FluxCD to ArgoCD:

1. **Infrastructure** - Already in ArgoCD ✅
2. **Applications** - Partially in ArgoCD, some still in Flux
3. **Goal** - Complete migration to ArgoCD, remove Flux

See: `kubernetes/docs/fluxcd-to-argocd-migration.md`

## Secrets Management

### SOPS Configuration

Kubernetes secrets managed via SOPS + Age encryption:

**Age Keys:**
- Admin keys: `admin-ndufour-2022`, `admin-ndufour-2023`
- Host-specific keys per service

**SOPS Files:**
- Located in `secrets/kubernetes/`
- Encrypted with `.sops.yaml` rules
- Decrypted at deployment time

### External Secrets

**Bitwarden Integration:**
- External Secrets Operator syncs secrets from Bitwarden
- ConfigMap with Bitwarden server URL
- Application-specific secrets pulled on demand

## Automated Updates

### Forgejo Workflow

**Location:** `.forgejo/workflows/bump-flake.yaml`

**Schedule:** Daily at 4am UTC

**Actions:**
1. Checkout repository
2. Install Nix
3. Run `nix flake update`
4. Auto-commit flake.lock changes

**Result:** Keeps NixOS dependencies up-to-date automatically

### Renovate

**Status:** Configured in home-ops (need to verify in avalanche)

Automatically updates:
- Docker image tags
- Helm chart versions
- Kubernetes manifests

## Repository Structure Notes

### kubernetes/ vs kubernetes/kubernetes/

The structure has two `kubernetes/` levels:

1. **Repository level:** `avalanche/kubernetes/`
   - Top-level directory in the avalanche monorepo
   - Contains ArgoCD apps, clusters, docs, etc.

2. **Flux legacy level:** `avalanche/kubernetes/kubernetes/`
   - Original home-ops directory structure
   - Contains Flux manifests to be migrated
   - Path preserved for compatibility during transition

This is temporary. Once Flux migration to ArgoCD is complete, the inner `kubernetes/` can be reorganized.

## Verification

### What to Test

**ArgoCD Applications:**
```bash
# Verify applications are recognized
kubectl get applications -n argocd

# Check application health
argocd app list

# Sync a test application
argocd app sync ctest
```

**Flux Kustomizations:**
```bash
# Verify kustomizations exist
kubectl get kustomizations -n flux-system

# Check reconciliation
flux get kustomizations
```

**Repository Access:**
```bash
# Test that Flux can pull from avalanche repo
flux reconcile source git home-ops-kubernetes

# Check for errors
kubectl logs -n flux-system -l app=source-controller
```

## Known Issues

### Path Adjustments Needed

If deploying fresh, ensure:
1. GitRepository URL points to avalanche (not home-ops) ✅
2. All Kustomization paths include `kubernetes/kubernetes/` prefix ✅
3. All ArgoCD apps use `kubernetes/base/` or `kubernetes/clusters/` ✅

### Pending Tasks

- [ ] Test ArgoCD sync with new paths
- [ ] Test Flux reconciliation with new repo
- [ ] Complete migration of remaining Flux manifests to ArgoCD
- [ ] Remove Flux once all manifests migrated
- [ ] Reorganize kubernetes/kubernetes/ directory structure

## Migration Summary

**Completed Actions:**
- ✅ Copied all 582 files from home-ops to kubernetes/
- ✅ Updated 43 ArgoCD Application manifests (paths + URLs)
- ✅ Updated 90+ Flux Kustomization manifests (paths)
- ✅ Updated Flux GitRepository URL (home-ops.git → avalanche.git)
- ✅ Merged justfiles with k8s- prefix
- ✅ Merged development tools (kubectl, argocd, helm, etc.)
- ✅ Updated documentation examples

**Result:**
Complete Kubernetes GitOps infrastructure migrated to avalanche monorepo with corrected paths and repository references.

---

*Last updated: 2025-11-02*
