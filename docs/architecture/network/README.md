# Network Architecture

## Overview

This directory contains network architecture documentation for the Avalanche infrastructure.

## Current Architecture (After Refactoring)

### Tailscale - Remote Access Only
**Purpose**: Secure remote access to home network from anywhere

- Subnet routing via `routy` gateway (advertising 10.1.0.0/24)
- Direct peer access for workstation and infrastructure hosts
- Split DNS for `.internal` domain
- No exit nodes (removed in favor of gluetun)

**Document**: [tailscale-architecture.md](tailscale-architecture.md)

### Gluetun - VPN Egress for Containerized Workloads
**Purpose**: VPN proxy for apps requiring IP masking or region selection

- Shared proxy service pattern (multiple apps share one VPN connection)
- Per-app sidecar pattern (dedicated VPN per app)
- Region/country selection (Iceland, Netherlands, etc.)
- Uses commercial VPN (ProtonVPN) - no VPS needed

**Document**: [vpn-egress-architecture.md](vpn-egress-architecture.md)

## Migration in Progress

We're currently migrating from the old architecture (Tailscale exit nodes + VPS) to the new architecture (Tailscale for access + gluetun for egress).

**Status**: Phase 1 complete (documentation), Phase 2 next (deploy shared VPN proxy)

**Document**: [network-architecture-migration.md](network-architecture-migration.md)

## Key Decisions

### Why Separate Remote Access and VPN Egress?

**Tailscale** is excellent for:
- ✅ Personal device access (phone, laptop)
- ✅ Peer-to-peer mesh networking
- ✅ Zero-config remote access
- ❌ NOT ideal for containerized workloads (complexity, inflexibility)

**Gluetun** is excellent for:
- ✅ Kubernetes sidecar or proxy pattern
- ✅ Region/provider selection per-app
- ✅ Standard K8s networking primitives
- ❌ NOT needed for remote access (Tailscale does this better)

**Conclusion**: Use the right tool for each job. Separation of concerns.

### Cost Comparison

**Old architecture**:
- VPS exit node: €4.49/month = €53.88/year
- ProtonVPN: €5-10/month (for qbittorrent)

**New architecture**:
- VPS: €0 (removed)
- ProtonVPN: €5-10/month (shared across all apps)
- **Savings**: €53.88/year

## Use Cases

### Remote Access to Home Services
→ **Use Tailscale**

Example: Access Kanidm, Vaultwarden, K8s services from phone or laptop while traveling.

### IRC Bot DDOS Protection
→ **Use Gluetun shared proxy**

Example: marmithon IRC bot routes through ProtonVPN Iceland, IRC network sees VPN IP instead of home IP.

### Torrent Client with VPN
→ **Use Gluetun sidecar**

Example: qbittorrent with dedicated gluetun sidecar, port forwarding enabled.

### Region-Specific Service Access
→ **Use Gluetun shared proxy with multiple regions**

Example: Service needs to appear from Netherlands - use `vpn-proxy-netherlands` service.

## Quick Reference

### Tailscale Hosts in Tailnet
- `routy` (100.121.204.6) - Subnet router
- `calypso` - Workstation
- `mysecrets` - Infrastructure services
- Phone/laptop - Personal devices

### Gluetun Deployments
- `qbittorrent` - Sidecar pattern (ProtonVPN Iceland)
- `vpn-proxy-iceland` (planned) - Shared proxy
- `vpn-proxy-netherlands` (planned) - Shared proxy

### Access Patterns

**From phone → Home service**:
```
Phone (Tailscale) → routy (subnet router) → 10.1.0.0/24 → Service
```

**IRC bot → IRC network**:
```
marmithon pod → vpn-proxy-iceland service → ProtonVPN → IRC network
```

**qbittorrent → Torrent peers**:
```
qbittorrent container → gluetun sidecar → ProtonVPN → Peers
```

## Related Documentation

- [Kanidm User Management](../../guides/identity/kanidm-user-management.md) - Identity provider used by Tailscale (future)
- [Migration Plan](../../migration/04-kubernetes-migration.md) - Kubernetes manifests migration context

---

*Last Updated: 2025-12-14*
