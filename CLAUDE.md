# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Avalanche is a unified infrastructure-as-code monorepo managing 16 NixOS hosts (ARM SBCs, x86 servers, and workstations) plus a Kubernetes cluster using GitOps. This consolidates configurations from previously separate repositories (snowy, snowpea, home-ops).

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
   - `base/`: Application definitions organized by category (apps, argocd, components, infra)
   - `clusters/`: Cluster-specific configurations
   - `kubernetes/`: Flux/ArgoCD manifests
   - Uses both ArgoCD (primary) and Flux (transitioning)

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
# Activate direnv (sets KUBECONFIG, SOPS_AGE_KEY_FILE)
direnv allow

# List all available commands
just

# Check flake validity
just nix-check

# Lint Nix files
just lint

# Format Nix files
just format
```

### NixOS Management
```bash
# List all NixOS hosts
just nix-list-hosts

# Deploy to remote host
just nix-deploy <hostname>

# Deploy locally (workstation)
just nix-switch <hostname>

# Deploy to all hosts (with confirmation)
just nix-deploy-all

# Build without deploying
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel

# Update flake inputs
just nix-update
```

### SD Card Images (for ARM hosts)
```bash
# Build SD card image
just sd-build <hostname>

# Build and flash
just sd-flash <hostname>
```

### Secrets Management (SOPS + Age)
```bash
# Update SOPS keys for all secrets
just sops-update

# Decrypt a secret file
sops secrets/<hostname>/secrets.sops.yaml
```

**SOPS Configuration**: `.sops.yaml` defines encryption rules by path regex:
- Each host has a dedicated age key
- Admin keys (*admin-ndufour-2022, *admin-ndufour-2023) can decrypt all secrets
- Secrets are organized by host/service in `secrets/` directory

### Kubernetes Management
```bash
# Get kubeconfig from cluster (kube-vip VIP: 10.1.0.5)
just k8s-get-kubeconfig

# Bootstrap Flux on cluster
just k8s-bootstrap

# Check sync status
argocd app list
flux get kustomizations
```

## Infrastructure Details

### NixOS Hosts (16 total)
- **Workstation**: calypso (ASUS ROG Strix, from snowy)
- **Infrastructure**: mysecrets (step-ca, Vaultwarden, Kanidm), eagle (Forgejo), possum (Garage S3, backups)
- **x86 Servers**: beacon, routy, cardinal
- **K3s Controllers**: opi01-03 (Orange Pi 5 Plus, aarch64)
- **K3s Workers**: raccoon00-05 (Raspberry Pi 4, aarch64)

### Key Technologies
- **Deployment**: nixos-rebuild over SSH to `<hostname>.internal` (Tailscale)
- **Secrets**: SOPS with Age encryption (keys in `~/.config/sops/age/keys.txt`)
- **Network**: Tailscale mesh VPN, kube-vip for K8s HA (VIP: 10.1.0.5)
- **Identity**: Kanidm at `https://auth.internal` (users: `username@auth.internal`)
- **GitOps**: ArgoCD (primary), Flux (legacy/transitioning)
- **Storage**: Longhorn (K8s), Garage S3 (object storage)

### Kubernetes Applications
- **Identity**: Vaultwarden (password manager)
- **Observability**: Prometheus stack, Grafana, InfluxDB2
- **Self-hosted**: Miniflux, SearXNG, Wallabag, Mealie, Wiki.js, Homepage
- **Home Automation**: RTL433, RTLAMR2MQTT, NUT UPS daemon
- **Infrastructure**: CloudNative-PG, cert-manager, External DNS, Nginx Ingress, Kyverno

## Identity Management (Kanidm)

**Location**: mysecrets host at `https://auth.internal`
**Documentation**: `docs/kanidm-user-management.md`

### Key Details
- **Domain**: `auth.internal` (user identities: `username@auth.internal`)
- **Origin**: `https://auth.internal` (accessed via Tailscale/internal network)
- **Admin accounts**:
  - `admin` - Basic administrative functions
  - `idm_admin` - Full identity management (create users, manage groups, OAuth2)
- **Database**: SQLite at `/srv/kanidm/kanidm.db` (bind mounted from `/var/lib/kanidm`)
- **Certificates**: Self-signed for backend (localhost), step-ca ACME for nginx frontend
- **Backups**: Daily at 22:00 UTC to `/srv/backups/kanidm` (keeps 7 versions)

### Administration
**All administration is CLI-based** (no web admin UI):
```bash
ssh mysecrets.internal

# Setup client config (first time only)
sudo tee /etc/kanidm/config <<EOF
uri = "https://auth.internal"
verify_ca = true
verify_hostnames = true
EOF

# Login as idm_admin
sudo kanidm login --name idm_admin

# Create user
sudo kanidm person create <username> "Display Name" --name idm_admin

# Set password (generates reset token URL)
sudo kanidm person credential create-reset-token <username> --name idm_admin

# Manage groups
sudo kanidm group add-members <groupname> <username> --name idm_admin
```

### Important Notes
- **Password-only auth**: By default requires passkeys. Set to password-only with:
  ```bash
  sudo kanidm group account-policy credential-type-minimum idm_all_persons any --name idm_admin
  ```
- **Recover admin accounts**:
  ```bash
  sudo kanidmd recover-account admin        # Basic admin
  sudo kanidmd recover-account idm_admin    # Identity admin
  ```
- **Domain warning**: Changing `domain` breaks all credentials (WebAuthn, OAuth tokens, etc.)
- **DNS requirement**: `domain` must exactly match DNS hostname for cookie security

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
- Push to git → ArgoCD/Flux syncs (for Kubernetes)
- Manual: `just nix-deploy <hostname>` builds locally, deploys remotely

### Testing Changes
- Build locally first: `nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel`
- Check flake: `just nix-check` or `nix flake check`
- Lint: `just lint` (uses statix)
- Format: `just format` (uses nixpkgs-fmt)

## Directory Conventions

- Host-specific config: `nixos/hosts/<hostname>/default.nix`
- Shared profiles: `nixos/profiles/` (imported via profileModules)
- Feature bundles: `nixos/personalities/` (imported directly in host configs)
- Secrets: `secrets/<hostname>/` (encrypted with SOPS)
- K8s apps: `kubernetes/base/apps/<category>/<app>/`

## Critical Notes

- **Do NOT** commit unencrypted secrets
- **Do NOT** modify stateVersion on existing systems (it's a NixOS compatibility marker, not a version to upgrade)
- **Always** test NixOS changes locally before `nix-deploy-all`
- **Remember** hosts are accessed via `<hostname>.internal` (Tailscale DNS)
- Kubernetes kubeconfig uses kube-vip VIP (10.1.0.5), not individual controller IPs
