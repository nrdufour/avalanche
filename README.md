# Project Avalanche 🏔️

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
├── src/                # Custom tools (sentinel gateway dashboard)
└── docs/               # Documentation
    └── migration/      # Migration process documentation
```

## Infrastructure Overview

### NixOS Hosts (15 total)

**Workstation (from snowy):**
- calypso: ASUS ROG Strix G513IM (personal laptop)

**Infrastructure Services:**
- mysecrets: Raspberry Pi 4 (8GB) - step-ca, Vaultwarden, Authentik
- hawk: Beelink SER5 - Forgejo
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
- Sentinel: Gateway dashboard for routy (services, DHCP, firewall, connections)

**Kubernetes:**
- ArgoCD: GitOps deployment
- Tailscale Operator: K8s-native Tailscale integration
- cert-manager, networking, security, observability components

**Automation & AI:**
- n8n: Workflow automation (`https://n8n.internal`)
- Ollama: Local LLM inference

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
# Deploy to a remote host
just nix-deploy <hostname>

# Deploy locally (for workstation)
just nix-switch <hostname>

# Deploy to all hosts (with confirmation)
just nix-deploy-all

# Build locally without applying
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
# Get kubeconfig from cluster
just k8s-get-kubeconfig

# Bootstrap cluster (TODO: update to bootstrap ArgoCD)
just k8s-bootstrap

# ArgoCD handles automatic deployment
# Check sync status:
argocd app list
```

## Technologies

- **NixOS**: Declarative system configuration
- **SOPS + Age**: Secrets management with encryption
- **Tailscale**: Mesh VPN
- **Authentik**: Identity provider (SSO/OIDC)
- **ArgoCD**: GitOps for Kubernetes
- **K3s**: Lightweight Kubernetes distribution
- **Just**: Command runner for deployment automation

## Known Issues & Workarounds

### Android 16 HTTPS Connectivity

If you experience intermittent HTTPS failures (port 443) on Android 16 devices with services like fly.dev, CDNs, or other providers, this may be due to Android 16's stricter validation of DSCP (Differentiated Services Code Point) packet markings. The router (routy) includes a global DSCP clearing rule that normalizes all packets to cs0, resolving this issue. This is a network-wide mitigation that should be transparent to most users.

## Migration & Deployment Status

**Phase 1: Migration** ✅ **COMPLETE**

This repository consolidates:
- ✅ Repository structure created
- ✅ NixOS server configurations (snowpea - 14 hosts)
- ✅ NixOS workstation config (snowy - calypso)
- ✅ Unified secrets management (SOPS + Age)
- ✅ Development environment (.envrc, default.nix)
- ✅ Justfile deployment automation
- ✅ Kubernetes manifests (home-ops)
- ✅ Forgejo workflow for automated updates

**Phase 2: Deployment** ✅ **COMPLETE**

- ✅ All 15 NixOS hosts deployed and operational
- ✅ AutoUpgrade configured (pulling from avalanche)
- ✅ ArgoCD applications synced (50+ apps)
- ✅ All infrastructure running from unified monorepo

See [docs/migration/](docs/migration/) for detailed migration documentation.

**Cloud infrastructure:** Pending future implementation

## Previous Repositories

Historical reference (now archived):
- snowy: <https://github.com/nrdufour/snowy>
- snowpea: <https://github.com/nrdufour/snowpea>
- home-ops: <https://github.com/nrdufour/home-ops>

## The Story

Infrastructure that starts with a single snowflake doesn't stay small for long. What began as a simple laptop config evolved into a fleet of servers, then a Kubernetes cluster, and now encompasses cloud resources and comprehensive identity management.

**avalanche** - because when infrastructure gains momentum, you need a single place to manage it all.

---

*Repository created: 2025-11-02*
