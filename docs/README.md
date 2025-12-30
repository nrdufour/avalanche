# Avalanche Documentation

Documentation for the Avalanche infrastructure-as-code monorepo.

## Architecture

System design documents, integration plans, and architectural decisions.

### Network
- [Tailscale Architecture](architecture/network/tailscale-architecture.md) - Remote access mesh VPN
- [VPN Egress Architecture](architecture/network/vpn-egress-architecture.md) - Gluetun-based VPN proxy for containerized workloads
- [Network Architecture Migration](architecture/network/network-architecture-migration.md) - Migration plan from Tailscale exit nodes to gluetun proxy pattern
- [K3s Network Sysctl Tuning](architecture/network/k3s-sysctl-tuning.md) - Kernel parameter optimization for K3s cluster nodes

### NPU (Neural Processing Unit)
- [RKNN NPU Integration Plan](architecture/npu/rknn-npu-integration-plan.md) - Orange Pi 5 Plus NPU integration for AI inference
- [NPU Inference Testing Guide](architecture/npu/npu-inference-testing-guide.md) - Testing and benchmarking RKNN models
- [Adding NPU Models](architecture/npu/npu-adding-models.md) - How to add new AI models to the NPU

### Surveillance
- [Camera Setup Plan](architecture/surveillance/camera-setup-plan.md) - Comprehensive home surveillance camera setup with Frigate NVR

## Guides

Step-by-step how-to guides and operational procedures.

### Operations
- [GitHub Outage Mitigation](guides/github-outage-mitigation.md) - Using local nixpkgs mirror during GitHub outages
- [Nix Distributed Builds](guides/nix-distributed-builds.md) - Build sharing and multi-architecture build coordination

### Identity Management
- [Kanidm User Management](guides/identity/kanidm-user-management.md) - Creating and managing users in Kanidm identity provider

### Upgrades
- [NixOS 25.11 Upgrade](guides/upgrades/nixos-25-11-upgrade.md) - Upgrading NixOS hosts to version 25.11

## Plans

Project plans, upgrade plans, and implementation proposals for future work.

- [Cilium CNI Migration Plan](plans/cilium-cni-migration-plan.md) - Migrating K3s cluster from Flannel to Cilium CNI
- [Forgejo Runner Upgrade Plan](plans/forgejo-runner-upgrade-plan.md) - Upgrading Forgejo Actions runners to latest version

## Troubleshooting

Known issues, workarounds, and debugging guides.

- [actions/checkout@v6 Forgejo Incompatibility](troubleshooting/actions-checkout-v6-forgejo-incompatibility.md) - Workaround for GitHub Actions checkout v6 compatibility issue

## Migration

Historical documents tracking the avalanche monorepo creation (consolidation of snowy, snowpea, and home-ops repositories).

- [00 - Migration Plan](migration/00-migration-plan.md) - Overall migration strategy and timeline
- [01 - NixOS Base Migration](migration/01-nixos-base-migration.md) - Base NixOS configuration from snowpea
- [02 - Justfile Migration](migration/02-justfile-migration.md) - Build commands and helper scripts
- [03 - Workstation Migration](migration/03-snowy-workstation-migration.md) - Calypso workstation from snowy
- [04 - Kubernetes Migration](migration/04-kubernetes-migration.md) - K8s manifests from home-ops

## Archive

Deprecated or superseded documentation kept for historical reference.

- [Tailscale with Exit Nodes](archive/tailscale-architecture-with-exit-nodes.md) - Old architecture using Tailscale exit nodes (superseded by gluetun proxy pattern)

## Contributing to Documentation

### Document Categories

- **architecture/**: High-level design, multiple components, long-term relevance. Subdirectories by domain.
- **guides/**: Instructional, specific tasks, frequently referenced. Subdirectories by topic.
- **plans/**: Forward-looking, may have tasks/checklists, may become obsolete after implementation.
- **troubleshooting/**: Problem-focused, may be temporary (until upstream fix), specific to versions.
- **migration/**: Historical, chronological, specific to avalanche monorepo creation.
- **archive/**: Out of date, replaced by newer docs, historical value only.

### File Naming Conventions

- Use kebab-case: `my-document-name.md`
- Be descriptive but concise
- Include version/date in filename if time-sensitive: `nixos-25-11-upgrade.md`
- Group related docs in subdirectories

### Writing Style

- Use markdown headers for structure
- Include a status badge if applicable (✅ Complete, 🚧 In Progress, ⏸️ Paused)
- Add creation and last-updated dates at the bottom
- Link to related documents
- Include troubleshooting/debugging commands where relevant

## Quick Links

### Most Referenced
- [Kanidm User Management](guides/identity/kanidm-user-management.md) - Frequently needed for user operations
- [Tailscale Architecture](architecture/network/tailscale-architecture.md) - Core network access setup
- [Network Migration Plan](architecture/network/network-architecture-migration.md) - Current major infrastructure change

### Latest Updates
- Cilium CNI Migration Plan - 2025-12-27 (migrating K3s from Flannel to Cilium)
- Network Architecture Migration - 2025-12-14 (separating remote access from VPN egress)
- Camera Setup Plan - 2025-12-14 (comprehensive surveillance system)
- Forgejo Runner Upgrade - 2025-12-13 (updating CI/CD runners)

---

*For general project information, see [avalanche-plan.md](../avalanche-plan.md) in the root directory.*
