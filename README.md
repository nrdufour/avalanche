# Project Avalanche

> "Started with a snowflake, became an avalanche"

## What is Avalanche?

Avalanche is a unified infrastructure-as-code monorepo that manages everything from laptops to servers to cloud resources using NixOS and Kubernetes.

## The Evolution

### snowflake > snowy > snowpea > home-ops > **avalanche**

- **snowflake**: A friend's NixOS flake that started it all
- **snowy**: Personal laptop configuration (calypso - ASUS ROG Strix)
- **snowpea**: Fleet of home ARM-based SBCs running NixOS
- **home-ops**: GitOps-managed Kubernetes cluster
- **avalanche**: Unified infrastructure bringing everything together

## Repository Structure

```
avalanche/
├── nixos/              # All NixOS configurations
│   ├── hosts/          # Individual machine configs
│   ├── profiles/       # Reusable profiles (hardware, roles)
│   ├── personalities/  # Additive feature sets (ham, chat, backups, etc.)
│   ├── modules/nixos/  # Custom NixOS modules
│   ├── pkgs/           # Custom package definitions
│   ├── overlays/       # Nixpkgs overlays
│   └── lib/            # Helper functions
├── kubernetes/         # Kubernetes GitOps manifests
│   ├── base/           # Application definitions
│   └── clusters/       # Cluster-specific configs
├── cloud/              # Cloud infrastructure
│   ├── nixos/          # NixOS-based VPS configs
│   └── terraform/      # Terraform for non-NixOS resources
├── secrets/            # Encrypted secrets (SOPS + Age)
└── docs/               # Documentation
    ├── architecture/   # System design documents
    ├── guides/         # How-to guides
    ├── plans/          # Implementation proposals
    ├── troubleshooting/# Known issues and workarounds
    └── migration/      # Migration process documentation
```

## Infrastructure Overview

### NixOS Hosts (15 active)

**Workstation:**
- calypso: ASUS ROG Strix G513IM

**Infrastructure Services:**
- mysecrets: Raspberry Pi 4 - step-ca, Vaultwarden, Kanidm
- hawk: Beelink SER5 Max - Forgejo, CI/CD
- possum: Raspberry Pi 4 - Samba, NFS (ZFS storage)

**x86 Servers:**
- routy: Main gateway (Knot DNS, DHCP, firewall)
- cardinal: x86 server

**Kubernetes Cluster:**
- K3s controllers: opi01-03 (Orange Pi 5 Plus, NPU-enabled)
- K3s workers: raccoon00-05 (Raspberry Pi 4)

**Decommissioned:** eagle (Forgejo migrated to hawk), beacon (nix-serve)

### Key Services

**Identity & Security:**
- step-ca: PKI/certificate authority (YubiKey HSM)
- Vaultwarden: Password management
- Kanidm: Identity provider (OIDC/OAuth2)

**Network:**
- Tailscale: Mesh VPN for remote access
- Gluetun: VPN egress proxy for containerized workloads
- Knot DNS: Authoritative DNS (routy)
- Sentinel: Gateway dashboard for routy

**Kubernetes:**
- ArgoCD: GitOps deployment
- cert-manager, Longhorn, networking, security, observability components

**Automation & AI:**
- n8n: Workflow automation
- NPU inference: RK3588 NPU on Orange Pi 5 Plus controllers

## Technologies

- **NixOS**: Declarative system configuration
- **SOPS + Age**: Secrets management with encryption
- **Tailscale**: Mesh VPN (remote access)
- **Gluetun**: VPN egress for K8s workloads
- **Kanidm**: Identity provider (SSO/OIDC)
- **ArgoCD**: GitOps for Kubernetes
- **K3s**: Lightweight Kubernetes distribution
- **Just**: Command runner for deployment automation

## Known Issues & Workarounds

### Android 16 HTTPS Connectivity

If you experience intermittent HTTPS failures (port 443) on Android 16 devices, this may be due to Android 16's stricter validation of DSCP packet markings. The router (routy) includes a global DSCP clearing rule that normalizes all packets to cs0, resolving this issue.

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
