# Tailscale Architecture

## Overview

Tailscale mesh VPN for secure remote access and exit node functionality (IRC bot DDOS protection).

**Tailnet Access**: New tailnet with Gmail authentication (created 2025-11-05)
**Primary Goal**: Exit node for IRC bot + complete remote access to home network
**Status**: ✅ Fully operational

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

## Current Architecture (WORKING)

### Principle
**Subnet routing from the gateway provides full network access**

routy (gateway) advertises the entire `10.1.0.0/24` subnet to Tailscale, providing seamless remote access to all services.

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

#### 6. routy (Main Gateway - Subnet Router) ✅
- **Purpose**: Advertise entire `10.1.0.0/24` subnet to tailnet
- **Configuration**: Subnet routing enabled, DNS disabled
- **Tailscale IP**: `100.121.204.6` (static)
- **Advertised routes**: `10.1.0.0/24`
- **NixOS module**: `nixos/hosts/routy/tailscale.nix`
- **Key settings**:
  - `useRoutingFeatures = "both"` (subnet routing enabled)
  - DNS disabled (this host provides DNS)
  - IP forwarding enabled
  - AdGuard Home listens on Tailscale IP for remote DNS

## Traffic Flows

### Remote Access (Phone → Services via Subnet Route)
```
Phone (Tailscale, cellular)
  ↓ (Tailscale mesh to subnet router)
routy (100.121.204.6, advertising 10.1.0.0/24)
  ↓ (IP forwarding, local network)
Any service on 10.1.0.0/24 (K8s, eagle, possum, etc.)
```

### Remote Access (Phone → Direct Tailscale Peers)
```
Phone (Tailscale)
  ↓ (Direct peer-to-peer)
calypso or mysecrets (Tailscale IPs)
  ↓ (Direct access)
Services on those hosts
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

## Key Implementation Details

### NixOS Module Workarounds

The Tailscale NixOS module doesn't properly persist `extraUpFlags`, so we use systemd services to apply settings:

**For routy** (`nixos/hosts/routy/tailscale.nix`):
```nix
systemd.services.tailscale-config = {
  # Runs after tailscaled starts
  ExecStart = pkgs.writeShellScript "tailscale-config" ''
    tailscale set --accept-dns=false
    tailscale set --advertise-routes=10.1.0.0/24
  '';
};
```

**For mysecrets** (`nixos/hosts/mysecrets/tailscale.nix`):
```nix
systemd.services.tailscale-disable-dns = {
  ExecStart = "tailscale set --accept-dns=false";
};
```

### Static IPs

Set in Tailscale admin console to ensure stable configuration:
- routy: `100.121.204.6` (used in AdGuard Home config)
- Other hosts: Can use dynamic IPs

### Split DNS Configuration

**Tailscale Admin Console**:
- Nameserver: `100.121.204.6` (routy's Tailscale IP)
- Restrict to domain: `internal`

**AdGuard Home** (routy):
```nix
dns.bind_hosts = [
  "10.0.0.54"
  "10.1.0.54"
  "100.121.204.6"  # Tailscale interface
];
```

### Lessons Learned

**What didn't work initially:**
- routy with subnet routing on GitHub-auth tailnet had routing issues (cause unclear)
- Creating new tailnet with Gmail auth and careful configuration resolved all issues

**Critical success factors:**
- Disable Tailscale DNS on infrastructure hosts (routy, mysecrets)
- Use systemd services to persist Tailscale settings (NixOS module limitation)
- Set static IPs for infrastructure hosts
- Enable IP forwarding for subnet routing
- Approve subnet routes in Tailscale admin console

**Result:** Replica of OPNsense Tailscale setup, now working on NixOS with full declarative configuration

---

*Created: 2025-11-04*
*Last Updated: 2025-11-05*
*Status: ✅ Production - Fully operational*
