# Tailscale Architecture (Refactored)

## Overview

Tailscale mesh VPN for **secure remote access only**. Exit node functionality removed in favor of gluetun-based VPN proxy service.

**Tailnet Access**: Gmail authentication tailnet
**Primary Goal**: Remote access to home network from anywhere
**Status**: ✅ Fully operational

## What Tailscale Does (Focus on Strengths)

### Core Use Case: Private Mesh Network
- **Remote access** to home services from anywhere
- **Zero-trust** peer-to-peer connections
- **Subnet routing** for full network access via gateway
- **Split DNS** for `.internal` domain resolution

### What Tailscale Does NOT Do Anymore
- ❌ Exit nodes for IRC bot or other egress traffic
- ❌ VPN proxy for region/country selection
- ❌ Outbound traffic masking

**Rationale**: Tailscale's exit node feature is excellent for personal devices (phone, laptop) but impractical for Kubernetes pods. Gluetun provides a better solution for containerized workloads requiring VPN egress.

## Architecture

### Hosts in Tailnet

#### 1. routy (Main Gateway - Subnet Router) ✅
- **Purpose**: Advertise entire `10.1.0.0/24` subnet to tailnet
- **Configuration**: Subnet routing enabled, DNS disabled
- **Tailscale IP**: `100.121.204.6` (static)
- **Advertised routes**: `10.1.0.0/24`
- **NixOS module**: `nixos/hosts/routy/tailscale.nix`
- **Key settings**:
  - `useRoutingFeatures = "both"` (subnet routing enabled)
  - DNS disabled (this host provides DNS via AdGuard Home)
  - IP forwarding enabled
  - AdGuard Home listens on Tailscale IP for remote DNS

#### 2. calypso (Workstation) ✅
- **Purpose**: Remote access to work from anywhere
- **Configuration**: Simple client, no special routing
- **NixOS module**: `nixos/hosts/calypso/tailscale.nix`

#### 3. mysecrets (Infrastructure Services) ✅
- **Purpose**: Access Kanidm, Vaultwarden, step-ca remotely
- **Configuration**: Simple client, advertise itself only
- **Services accessible**:
  - https://auth.internal (Kanidm)
  - https://mysecrets.internal (Vaultwarden)
  - step-ca for certificates
- **NixOS module**: `nixos/hosts/mysecrets/tailscale.nix`

#### 4. Phone ✅
- **Purpose**: Access home services remotely
- **Configuration**: Tailscale mobile app
- **Status**: Already configured and working

#### 5. Future: Other hosts as needed
- **Principle**: Only join hosts to tailnet if they need remote access
- **Not needed**: K8s nodes (accessible via subnet routing)

### VPS Exit Node (To Be Removed)

**Current Status**: Hetzner VPS running as Tailscale exit node (~€4.49/month)

**Removal Plan**:
- VPS is no longer needed for IRC bot egress (using gluetun instead)
- Can be decommissioned once gluetun-based proxy service is tested
- Saves €4.49/month (~$5/month)

**Rationale**:
- Tailscale Kubernetes Operator is complex and requires pod-level network configuration
- Gluetun sidecar pattern is simpler and more flexible for containerized workloads
- VPS exit node adds cost without providing value over commercial VPN

## Traffic Flows

### Remote Access (Phone → Services via Subnet Route)
```
Phone (Tailscale, cellular)
  ↓ (Tailscale mesh to subnet router)
routy (100.121.204.6, advertising 10.1.0.0/24)
  ↓ (IP forwarding, local network)
Any service on 10.1.0.0/24 (K8s, hawk, possum, etc.)
```

### Remote Access (Phone → Direct Tailscale Peers)
```
Phone (Tailscale)
  ↓ (Direct peer-to-peer)
calypso or mysecrets (Tailscale IPs)
  ↓ (Direct access)
Services on those hosts
```

### Workstation Access
```
calypso (Tailscale)
  ↓ (Tailscale mesh)
mysecrets (Tailscale)
  ↓ (Access to services)
```

## Authentication

**Current**: Gmail OAuth
**Future Option**: Kanidm OIDC (requires public exposure or keep Gmail)

**Decision**: Keep Gmail auth for now (pragmatic)
- No chicken-and-egg problem
- Secure enough for personal use
- Can migrate to Kanidm later if needed

## Split DNS Configuration

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

## NixOS Module Workarounds

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

## Security Considerations

### Firewall Rules
- Tailscale interface (`tailscale0`) is trusted on all hosts
- Individual services still need proper authentication (Kanidm)
- No port forwarding required (Tailscale is outbound-only)

### Access Control
- Tailscale ACLs control which hosts can talk to each other
- Default: All hosts in tailnet can reach each other
- Future: Use ACLs to restrict access (e.g., phone can only access mysecrets)

## Troubleshooting

### If Routing Issues Occur
1. **Check**: Firewall rules for `tailscale0` interface
2. **Check**: `ip route` for conflicting routes
3. **Check**: Subnet routes approved in Tailscale admin console
4. **Check**: IP forwarding enabled on routy

### Debugging Commands
```bash
# Check Tailscale status
sudo tailscale status

# Check routes
ip route | grep tailscale

# Test connectivity
tailscale ping <hostname>
```

## Migration from Previous Architecture

### Removed Components
- ❌ Tailscale Kubernetes Operator (too complex for our needs)
- ❌ VPS exit node (unnecessary cost)
- ❌ Exit node configuration for IRC bot (moved to gluetun)

### What Remains
- ✅ Subnet routing via routy (core functionality)
- ✅ Direct peer access (calypso, mysecrets)
- ✅ Split DNS configuration
- ✅ Remote access for phone/laptop

### Benefits of Refactored Architecture
- **Simpler**: Tailscale only does what it's best at (mesh VPN)
- **Cheaper**: No VPS cost (~€54/year saved)
- **More flexible**: Gluetun allows region/country selection per-service
- **Better separation**: Network access (Tailscale) vs egress VPN (Gluetun) are distinct concerns

## Cost Analysis

**Old Architecture**:
- VPS for exit node: €4.49/month (~$5/month)
- **Total**: €53.88/year (~$60/year)

**New Architecture**:
- VPS: €0 (removed)
- Gluetun: €0 (uses commercial VPN subscription - already budgeted separately)
- **Total**: €0/year

**Savings**: €53.88/year (~$60/year)

## References

- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Tailscale ACLs](https://tailscale.com/kb/1018/acls)
- Related docs: `vpn-egress-architecture.md` (gluetun-based VPN proxy)

## Lessons Learned

**What didn't work initially:**
- routy with subnet routing on GitHub-auth tailnet had routing issues (cause unclear)
- Creating new tailnet with Gmail auth and careful configuration resolved all issues

**Critical success factors:**
- Disable Tailscale DNS on infrastructure hosts (routy, mysecrets)
- Use systemd services to persist Tailscale settings (NixOS module limitation)
- Set static IPs for infrastructure hosts
- Enable IP forwarding for subnet routing
- Approve subnet routes in Tailscale admin console

**Result:** Clean, focused Tailscale deployment that does one thing well: secure remote access

---

*Created: 2025-11-04*
*Last Updated: 2025-12-14 (Refactored to remove exit node functionality)*
*Status: ✅ Production - Fully operational*
