# Project Avalanche

> "Started with a snowflake, became an avalanche"

## What is Avalanche?

Avalanche is a unified infrastructure-as-code monorepo that manages everything from laptops to servers to cloud resources using NixOS and Kubernetes.

## The Evolution

### snowflake → snowy → snowpea → home-ops → **avalanche**

- **snowflake**: A friend's NixOS flake that started it all
- **snowy**: Personal laptop configuration (calypso - ASUS ROG Strix)
- **snowpea**: Fleet of 15+ home ARM-based SBCs running NixOS
- **home-ops**: GitOps-managed Kubernetes cluster
- **avalanche**: Unified infrastructure bringing everything together

## Repository Structure

```
avalanche/
├── nixos/              # All NixOS configurations
│   ├── hosts/          # Individual machine configs
│   ├── profiles/       # Reusable profiles (hardware, roles)
│   ├── modules/nixos/  # Custom NixOS modules
│   └── lib/            # Helper functions
├── kubernetes/         # Kubernetes GitOps manifests
│   ├── base/           # Application definitions
│   ├── clusters/       # Cluster-specific configs
│   └── docs/           # K8s documentation
├── cloud/              # Cloud infrastructure
│   ├── nixos/          # NixOS-based VPS configs
│   └── terraform/      # Terraform for non-NixOS resources
├── secrets/            # Encrypted secrets (SOPS)
│   ├── nixos/
│   ├── kubernetes/
│   └── cloud/
└── docs/               # Documentation
    └── migration/      # Migration process documentation
```

## Infrastructure Overview

### NixOS Hosts (15 total)

**Workstation (from snowy):**
- calypso: ASUS ROG Strix G513IM (personal laptop)

**Infrastructure Services:**
- mysecrets: Raspberry Pi 4 (8GB) - step-ca, Vaultwarden, Authentik
- eagle: Raspberry Pi - Forgejo
- possum: Raspberry Pi - Garage S3, backups
- beacon, routy, cardinal: x86 servers

**Kubernetes Cluster:**
- K3s controllers: opi01-03 (Orange Pi 5 Plus)
- K3s workers: raccoon00-05 (Raspberry Pi 4)

### Key Services

**Identity & Security:**
- step-ca: PKI/certificate authority
- Vaultwarden: Password management
- Authentik: SSO/identity provider (OIDC)

**Network:**
- Tailscale: Mesh VPN with exit node support
- knot-dns: DNS server

**Kubernetes:**
- ArgoCD: GitOps deployment
- Tailscale Operator: K8s-native Tailscale integration
- cert-manager, networking, security, observability components

## Quick Start

### Available Commands

```bash
# List all available commands
just

# Check flake validity
just nix-check

# List all NixOS hosts
just nix-list-hosts
```

### Deploying NixOS Hosts

```bash
# Deploy a specific host
just nix-deploy <hostname>

# Deploy to all hosts (with confirmation)
just nix-deploy-all

# Build locally
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel
```

### Managing Secrets

```bash
# Update SOPS keys for all secrets
just sops-update
```

### SD Card Images

```bash
# Build SD card image for a host
just sd-build <hostname>

# Build and flash SD card image
just sd-flash <hostname>
```

### Managing Kubernetes

```bash
# ArgoCD handles automatic deployment
# Manual apply if needed:
kubectl apply -k kubernetes/clusters/main/
```

## Technologies

- **NixOS**: Declarative system configuration
- **SOPS**: Secrets management with Age encryption
- **Tailscale**: Mesh VPN
- **Authentik**: Identity provider
- **ArgoCD**: GitOps for Kubernetes
- **K3s**: Lightweight Kubernetes

## Migration Status

This repository consolidates:
- ✅ Repository structure created
- ✅ NixOS server configurations (snowpea - 14 hosts)
- ✅ NixOS workstation config (snowy - calypso)
- ✅ Unified secrets management (SOPS + Age)
- ✅ Development environment (.envrc, default.nix)
- ✅ Justfile deployment automation
- ⏳ Kubernetes manifests (home-ops)
- ⏳ Cloud infrastructure setup

**All 15 NixOS hosts validated with `nix flake check` ✅**

See [docs/migration/](docs/migration/) for detailed migration documentation.

## Previous Repositories

Historical reference (now archived):
- snowy: `/home/ndufour/Documents/code/projects/ops/snowy`
- snowpea: `/home/ndufour/Documents/code/projects/ops/snowpea`
- home-ops: `/home/ndufour/Documents/code/projects/ops/home-ops`

## The Story

Infrastructure that starts with a single snowflake doesn't stay small for long. What began as a simple laptop config evolved into a fleet of servers, then a Kubernetes cluster, and now encompasses cloud resources and comprehensive identity management.

**avalanche** - because when infrastructure gains momentum, you need a single place to manage it all.

---

*Repository created: 2025-11-02*
