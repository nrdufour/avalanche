# Tailscale Architecture

## Overview

Tailscale mesh VPN for secure remote access and exit node functionality (IRC bot DDOS protection).

**Tailnet Access**: Existing tailnet (GitHub auth)
**Primary Goal**: Exit node for IRC bot + secure remote access to services

## Previous Architecture (PROBLEMATIC - Disabled)

### What Was Tried
- Tailscale on `routy` (main gateway/router)
- Subnet routing: advertising 10.1.0.0/24
- Goal: Access home services from phone

### Why It Failed
- **Routing conflicts**: routy is the actual gateway for 10.1.0.0/24
- Advertising the same subnet via Tailscale created routing loops
- Traffic didn't know: physical network or Tailscale?
- Result: Network instability, disabled

## New Architecture (CLEAN)

### Principle
**Never run Tailscale on your network gateway/router**

Individual hosts join the tailnet, not the gateway itself.

### Hosts in Tailnet

#### 1. calypso (Workstation)
- **Purpose**: Remote access to work from anywhere
- **Configuration**: Simple client, no special routing
- **NixOS module**: `nixos/hosts/calypso/tailscale.nix`

#### 2. mysecrets (Infrastructure Services)
- **Purpose**: Access Kanidm, Vaultwarden, step-ca remotely
- **Configuration**: Simple client, advertise itself only
- **Services accessible**:
  - https://auth.internal (Kanidm)
  - https://mysecrets.internal (Vaultwarden)
  - step-ca for certificates
- **NixOS module**: `nixos/hosts/mysecrets/tailscale.nix`

#### 3. K8s Cluster (via Tailscale Operator)
- **Purpose**: Exit node for IRC bot (marmithon)
- **Configuration**: Kubernetes operator, pod-level routing
- **Deployment**: ArgoCD-managed in `kubernetes/base/infra/tailscale/`
- **Exit Node**: Configured per-pod via annotations

#### 4. VPS (Exit Node)
- **Purpose**: Exit point for IRC bot traffic
- **Configuration**: NixOS with `--advertise-exit-node`
- **Provider**: Hetzner Cloud or DigitalOcean (~$5/month)
- **Benefits**: IRC sees VPS IP, not home IP

#### 5. Phone (Already Working)
- **Purpose**: Access home services remotely
- **Status**: Already configured and working

### NOT in Tailnet

#### routy (Main Gateway)
- **Status**: Tailscale disabled and will remain disabled
- **Reason**: Causes routing conflicts with physical network
- **Alternative**: Individual hosts connect directly

## Traffic Flows

### Remote Access (Phone → Services)
```
Phone (Tailscale)
  ↓ (Tailscale mesh)
mysecrets (Tailscale)
  ↓ (Local network)
Services (Kanidm, Vaultwarden)
```

### Exit Node (IRC Bot)
```
IRC Bot (K8s Pod)
  ↓ (Tailscale operator, annotation-based routing)
VPS Exit Node (Tailscale)
  ↓ (Public internet)
IRC Network (sees VPS IP)
```

### Workstation Access
```
calypso (Tailscale)
  ↓ (Tailscale mesh)
mysecrets (Tailscale)
  ↓ (Access to services)
```

## Authentication

**Current**: GitHub OAuth
**Future Option**: Kanidm OIDC (requires public exposure or keep GitHub)

**Decision**: Keep GitHub auth for now (pragmatic)
- No chicken-and-egg problem
- Secure enough for personal use
- Can migrate to Kanidm later if needed

## Implementation Steps

1. **Reuse existing tailnet** (GitHub auth)
2. **Deploy on calypso** (workstation) - test basic connectivity
3. **Deploy on mysecrets** (services) - test service access
4. **Provision VPS** (exit node) - Hetzner Cloud ARM or x86
5. **Deploy Tailscale operator** in K8s cluster
6. **Configure IRC bot** to use exit node
7. **Test DDOS protection** - verify IRC sees VPS IP

## Security Considerations

### Firewall Rules
- Tailscale interface (`tailscale0`) is trusted on all hosts
- Individual services still need proper authentication (Kanidm)
- No port forwarding required (Tailscale is outbound-only)

### Access Control
- Tailscale ACLs control which hosts can talk to each other
- Default: All hosts in tailnet can reach each other
- Future: Use ACLs to restrict access (e.g., phone can only access mysecrets)

### Exit Node Security
- VPS is isolated (no home network access)
- Only IRC bot traffic goes through it
- DDOS hits VPS, not home network
- VPS can be nuked and recreated easily

## Troubleshooting

### If Routing Issues Occur
1. **Check**: Is Tailscale enabled on routy? (It shouldn't be)
2. **Check**: Are any hosts advertising subnets? (They shouldn't be)
3. **Check**: Firewall rules for `tailscale0` interface
4. **Check**: `ip route` for conflicting routes

### Debugging Commands
```bash
# Check Tailscale status
sudo tailscale status

# Check routes
ip route | grep tailscale

# Test connectivity
tailscale ping <hostname>

# Check exit node
tailscale status | grep "Exit node"
```

## Cost Analysis

**VPS for Exit Node:**
- Hetzner Cloud CAX11 (ARM): €4.49/month (~$5)
- DigitalOcean Basic Droplet: $6/month
- Scaleway DEV1-S: €~7/month

**Total Monthly Cost**: ~$5-7 for IRC bot DDOS protection

## References

- [Tailscale Exit Nodes](https://tailscale.com/kb/1103/exit-nodes)
- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets) (what NOT to do on routy)
- Project plan: `avalanche-plan.md`

---

*Created: 2025-11-04*
*Status: Planning phase*
