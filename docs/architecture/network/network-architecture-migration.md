# Network Architecture Migration Plan

## Overview

Refactoring network architecture to use the right tool for each job:
- **Tailscale**: Remote access to home network (what it does best)
- **Gluetun**: VPN egress for containerized workloads (simpler, more flexible)

## Current State (Before Migration)

### Tailscale Architecture
- ✅ routy: Subnet router advertising 10.1.0.0/24
- ✅ calypso: Workstation remote access
- ✅ mysecrets: Infrastructure services access
- ✅ Phone: Remote access via Tailscale app
- 🚧 VPS exit node: Hetzner CAX11 (~€4.49/month) - **TO BE REMOVED**
- ❌ Tailscale Kubernetes Operator: Not deployed (planned but never implemented)

### VPN Egress
- ✅ qbittorrent: Gluetun sidecar (ProtonVPN Iceland) - **WORKING WELL**
- ❌ IRC bot (marmithon): No VPN egress yet - **NEEDS PROTECTION**

### Problems
1. **VPS cost**: €53.88/year for underutilized exit node
2. **Wrong tool**: Tailscale exit nodes impractical for K8s pods
3. **Complexity**: Tailscale Kubernetes Operator adds unnecessary complexity
4. **Limited flexibility**: Can't easily select region/country per-service

## Target State (After Migration)

### Tailscale (Focused on Remote Access)
- ✅ routy: Subnet router (unchanged)
- ✅ calypso: Workstation access (unchanged)
- ✅ mysecrets: Infrastructure services (unchanged)
- ✅ Phone: Remote access (unchanged)
- ❌ VPS exit node: **REMOVED** (save €53.88/year)
- ❌ Tailscale Kubernetes Operator: **NOT DEPLOYED** (not needed)

### Gluetun (VPN Egress)
- ✅ qbittorrent: Sidecar pattern (unchanged)
- ✅ Shared proxy service: Iceland + Netherlands regions
- ✅ IRC bot (marmithon): Uses shared proxy
- ✅ Future services: Can select region/provider as needed

### Benefits
- **Simpler**: Each tool does one thing well
- **Cheaper**: €53.88/year saved (no VPS)
- **More flexible**: Easy region selection, multiple providers
- **Better for K8s**: Standard sidecar/proxy patterns instead of operator complexity

## Migration Steps

### Phase 1: Update Documentation ✅ (Current Phase)

**Files created/updated**:
- [x] `docs/tailscale-architecture-refactored.md` - Focused on remote access only
- [x] `docs/vpn-egress-architecture.md` - Gluetun-based VPN proxy patterns
- [x] `docs/network-architecture-migration.md` - This document

**Files to archive**:
- [ ] Move `docs/tailscale-architecture.md` to `docs/archive/tailscale-architecture-old.md`

**Files to update**:
- [ ] Update `avalanche-plan.md` to reflect new architecture
- [ ] Update `README.md` if it references old architecture

### Phase 2: Deploy Shared VPN Proxy Service

**Location**: `kubernetes/base/infra/network/vpn-proxy/`

**Tasks**:
- [ ] Create namespace: `vpn-proxy`
- [ ] Create SOPS secret with ProtonVPN credentials (reuse from qbittorrent)
- [ ] Deploy Iceland proxy: `vpn-proxy-iceland`
  - HTTP proxy: port 8888
  - SOCKS5 proxy: port 8388
  - Health check: port 9999
- [ ] Deploy Netherlands proxy: `vpn-proxy-netherlands` (backup region)
- [ ] Create Services for each proxy
- [ ] Create ArgoCD Application: `base/infra/vpn-proxy-app.yaml`
- [ ] Test from debug pod:
  ```bash
  kubectl run -it --rm debug --image=curlimages/curl -- sh
  export HTTP_PROXY=http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888
  curl ifconfig.me  # Should show ProtonVPN Iceland IP
  ```

**Files to create**:
```
kubernetes/base/infra/network/vpn-proxy/
├── kustomization.yaml
├── namespace.yaml
├── secrets.sops.yaml              # ProtonVPN credentials
├── deployment-iceland.yaml        # Primary exit point
├── deployment-netherlands.yaml    # Alternative region
├── service-iceland.yaml
├── service-netherlands.yaml
└── README.md                      # Usage instructions

kubernetes/base/infra/vpn-proxy-app.yaml  # ArgoCD Application
```

**Example secret structure** (encrypted with SOPS):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vpn-proxy-protonvpn
  namespace: vpn-proxy
type: Opaque
stringData:
  WIREGUARD_PRIVATE_KEY: <key from ProtonVPN>
  WIREGUARD_ADDRESSES: <address from ProtonVPN>
```

**Reference**: Can copy credentials from existing qbittorrent secret

### Phase 3: Migrate IRC Bot (marmithon)

**Investigation needed**:
- [ ] Check if marmithon supports `HTTP_PROXY`/`HTTPS_PROXY` environment variables
- [ ] Check if marmithon supports SOCKS5 proxy configuration
- [ ] Review marmithon source code for proxy support

**Option A: HTTP Proxy (Preferred if supported)**

Update `kubernetes/base/apps/irc/marmithon/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: marmithon
          env:
            # Add proxy configuration
            - name: HTTP_PROXY
              value: "http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888"
            - name: HTTPS_PROXY
              value: "http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888"
            - name: NO_PROXY
              value: "localhost,127.0.0.1,10.0.0.0/8,*.cluster.local"
```

**Option B: SOCKS5 Proxy (If HTTP proxy not supported)**

Configure IRC connection to use SOCKS5:
```yaml
env:
  - name: IRC_PROXY
    value: "socks5://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8388"
```

**Option C: Sidecar Pattern (Fallback if no proxy support)**

If marmithon doesn't support proxies, use gluetun sidecar (like qbittorrent):
```yaml
spec:
  template:
    spec:
      containers:
        - name: marmithon
          # Main container
        - name: gluetun
          # VPN sidecar (shares network namespace)
```

**Testing**:
```bash
# Deploy updated marmithon
kubectl apply -k kubernetes/base/apps/irc/marmithon/

# Check IRC bot's egress IP from logs
kubectl logs -n irc deployment/marmithon

# Verify IRC network sees VPN IP (not home IP)
# Connect to IRC manually and check /whois response
```

**Validation period**: Run for 1 week to ensure stability

### Phase 4: Cleanup and Cost Savings

**VPS Decommission**:
- [ ] Verify IRC bot stable on new VPN proxy (1 week minimum)
- [ ] SSH to Hetzner VPS and backup any data (if any)
- [ ] Delete VPS from Hetzner Cloud Console
- [ ] Remove VPS from Tailscale admin console
- [ ] **Savings**: €4.49/month = €53.88/year

**Documentation cleanup**:
- [ ] Archive old Tailscale architecture document
- [ ] Update references in other docs
- [ ] Update `avalanche-plan.md` with cost savings

**NixOS cleanup** (if VPS was in avalanche):
- [ ] Remove VPS host configuration from `flake.nix` (if present)
- [ ] Remove VPS secrets from `secrets/` directory
- [ ] Remove VPS from `.sops.yaml` creation_rules

### Phase 5: Future Enhancements (Optional)

**Add more regions** (as needed):
- [ ] Sweden proxy: `vpn-proxy-sweden`
- [ ] Germany proxy: `vpn-proxy-germany`
- [ ] US East proxy: `vpn-proxy-us-east`

**Add NetworkPolicy** (security hardening):
```yaml
# Enforce VPN usage for IRC bot
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: marmithon-require-vpn
  namespace: irc
spec:
  podSelector:
    matchLabels:
      app: marmithon
  policyTypes:
    - Egress
  egress:
    # Only allow egress through VPN proxy
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: vpn-proxy
      ports:
        - port: 8888
        - port: 8388
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
```

**Add Prometheus monitoring**:
- [ ] Create ServiceMonitor for gluetun metrics
- [ ] Create PrometheusRule for VPN proxy alerts
- [ ] Add Grafana dashboard for VPN proxy health

**Try alternative VPN providers**:
- [ ] Test Mullvad VPN (€5/month, anonymous)
- [ ] Test IVPN (strong privacy, port forwarding)
- [ ] Compare performance and privacy

## Decision Log

### Why Not Tailscale Exit Nodes for K8s?

**Considered**:
- Tailscale Kubernetes Operator
- Pod annotations for exit node routing
- VPS as dedicated exit node

**Issues found**:
1. **Complexity**: Operator adds CRD, requires pod-level network configuration
2. **Pod lifecycle**: Tailscale connection tied to pod lifecycle (restart = new connection)
3. **Resource overhead**: Each pod needs Tailscale sidecar or operator manages it
4. **Limited flexibility**: Hard to switch regions/providers per-pod
5. **Community adoption**: Gluetun has more K8s examples and community support

**Conclusion**: Tailscale exit nodes are excellent for personal devices (phone, laptop) but impractical for containerized workloads in Kubernetes.

### Why Gluetun?

**Advantages**:
1. **Proven pattern**: Already working well for qbittorrent
2. **Simple**: Standard Kubernetes sidecar or shared proxy service
3. **Flexible**: Choose provider, region, protocol per-service
4. **Well-supported**: Active development, good documentation
5. **Feature-rich**: Kill switch, port forwarding, multiple protocols

**Alternatives considered**:
- **WireGuard sidecar**: Too low-level, need to manage configs manually
- **OpenVPN sidecar**: Older protocol, less performant
- **Commercial VPN containers**: Vendor lock-in, less flexible

**Conclusion**: Gluetun is the best-in-class solution for VPN egress in Kubernetes.

### Why ProtonVPN?

**Current choice**: Already using for qbittorrent

**Advantages**:
- Port forwarding (important for torrents)
- WireGuard support (fast, modern)
- Good privacy policy
- Multiple simultaneous connections (Plus plan)

**Cost**:
- ProtonVPN Plus: ~€5-10/month
- Can reuse same credentials across all gluetun instances
- **No additional cost** for shared proxy pattern

**Future**: Could add Mullvad or IVPN as alternative providers for diversity

## Testing Checklist

### Phase 2: VPN Proxy Service
- [ ] VPN proxy pod starts successfully
- [ ] Health check endpoint responds (port 9999)
- [ ] HTTP proxy works (port 8888)
- [ ] SOCKS5 proxy works (port 8388)
- [ ] Egress IP shows ProtonVPN Iceland IP
- [ ] No IP leaks (test with ipleak.net)
- [ ] VPN reconnects after network interruption
- [ ] Service resolves from other namespaces

### Phase 3: IRC Bot Migration
- [ ] IRC bot connects successfully
- [ ] IRC network sees VPN IP (not home IP)
- [ ] IRC bot functionality unchanged
- [ ] No connection drops or instability
- [ ] Logs show no proxy errors
- [ ] Can switch between Iceland/Netherlands proxy

### Phase 4: Cleanup
- [ ] VPS completely removed from Hetzner
- [ ] Tailscale admin console shows VPS offline
- [ ] No references to VPS in git repo
- [ ] Documentation updated
- [ ] Cost savings confirmed (€4.49/month)

## Rollback Plan

### If Phase 3 (IRC bot) fails

**Symptoms**:
- IRC bot can't connect
- Excessive connection drops
- IRC network blocks VPN IP

**Rollback steps**:
1. Remove proxy configuration from marmithon deployment
2. Redeploy without proxy: `kubectl rollout undo deployment/marmithon -n irc`
3. IRC bot returns to direct connection (no VPN protection)
4. Investigate proxy compatibility issues
5. Consider Option C (sidecar pattern) instead

**Keep VPS running** until IRC bot stable on new architecture (minimum 1 week)

### If VPN proxy service fails

**Symptoms**:
- VPN proxy pod crashlooping
- Health checks failing
- ProtonVPN authentication errors

**Rollback steps**:
1. Check gluetun logs: `kubectl logs -n vpn-proxy deployment/vpn-proxy-iceland`
2. Verify credentials in secret
3. Test with debug pod and sidecar pattern
4. Check ProtonVPN account status
5. If unrecoverable, fall back to sidecar pattern for each app

## Success Metrics

### Quantitative
- **Cost savings**: €53.88/year (VPS removal)
- **Resource usage**: Lower than N separate VPN connections
- **Stability**: > 99.9% uptime for VPN proxy service
- **Performance**: < 50ms added latency via VPN proxy

### Qualitative
- **Simpler architecture**: Fewer moving parts
- **Better separation of concerns**: Remote access vs egress clearly separated
- **More flexible**: Easy to add regions/providers
- **More maintainable**: Standard K8s patterns

## Timeline

**Phase 1** (Documentation): **DONE** ✅
**Phase 2** (Deploy VPN proxy): 1-2 hours
**Phase 3** (Migrate IRC bot): 2-4 hours + 1 week validation
**Phase 4** (Cleanup): 1 hour
**Phase 5** (Future): Ongoing as needed

**Total time**: ~1 day of work + 1 week validation period

## References

- [Tailscale Architecture (Refactored)](./tailscale-architecture-refactored.md)
- [VPN Egress Architecture](./vpn-egress-architecture.md)
- [Gluetun Documentation](https://github.com/qdm12/gluetun)
- [ProtonVPN WireGuard Setup](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)

---

*Created: 2025-12-14*
*Status*: 🚧 Phase 1 Complete - Documentation updated
