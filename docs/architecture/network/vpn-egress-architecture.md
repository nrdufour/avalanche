# VPN Egress Architecture (Gluetun-based)

## Overview

Gluetun-based VPN proxy service for containerized workloads requiring outbound traffic masking, region selection, or IP protection.

**Primary Use Cases**:
- IRC bot DDOS protection (marmithon)
- Region/country-specific egress for future services
- Torrenting and privacy-sensitive traffic (qbittorrent)

**Status**: ✅ Proven pattern (qbittorrent), ready to expand

## Why Gluetun (Not Tailscale Exit Nodes)

### Advantages Over Tailscale Exit Nodes

1. **Simpler for Kubernetes workloads**
   - Sidecar container pattern (well-understood)
   - No operator or CRD management
   - Per-pod configuration via standard Kubernetes primitives

2. **More flexible**
   - Choose VPN provider per-service (ProtonVPN, Mullvad, etc.)
   - Select region/country per-workload
   - VPN credentials isolated per-service (secrets management)

3. **Better for containerized workloads**
   - Native Kubernetes pod networking
   - Standard health checks and probes
   - Works with existing network policies

4. **No VPS cost**
   - Uses commercial VPN subscription (ProtonVPN, Mullvad, etc.)
   - No need to maintain separate exit node infrastructure
   - Scales horizontally without additional cost

5. **Proven pattern**
   - Already working well for qbittorrent
   - Community support and documentation
   - Actively maintained

### When Tailscale Exit Nodes Make Sense
- **Personal devices** (phone, laptop) - Tailscale mobile/desktop apps work great
- **Roaming access** - Need to access home network *and* use exit node
- **Not for**: Stateless pods in Kubernetes

## Architecture Patterns

### Pattern 1: Sidecar Container (Current - qbittorrent)

**Use case**: Single application needs VPN egress

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        # Main application
        - name: app
          # Shares network namespace with gluetun
          # All traffic routes through VPN

        # Gluetun VPN sidecar
        - name: gluetun
          image: ghcr.io/qdm12/gluetun:v3.40.1
          securityContext:
            capabilities:
              add:
                - NET_ADMIN  # Required for routing
          env:
            - name: VPN_SERVICE_PROVIDER
              value: "protonvpn"
            - name: SERVER_COUNTRIES
              value: "Iceland"
```

**Pros**:
- Simple and self-contained
- Isolated VPN configuration per-app
- No shared state

**Cons**:
- Each pod gets own VPN connection
- Multiple pods = multiple VPN connections
- Resource overhead (one gluetun per pod)

### Pattern 2: Shared VPN Proxy Service (Proposed)

**Use case**: Multiple applications share VPN egress, select region dynamically

```yaml
# VPN Proxy Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vpn-proxy-iceland
spec:
  template:
    spec:
      containers:
        - name: gluetun
          image: ghcr.io/qdm12/gluetun:v3.40.1
          env:
            - name: VPN_SERVICE_PROVIDER
              value: "protonvpn"
            - name: SERVER_COUNTRIES
              value: "Iceland"
            - name: HTTPPROXY
              value: "on"  # Enable HTTP proxy
            - name: SHADOWSOCKS
              value: "on"  # Enable SOCKS5 proxy
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: vpn-proxy-iceland
spec:
  selector:
    app: vpn-proxy-iceland
  ports:
    - name: http-proxy
      port: 8888      # HTTP proxy
    - name: socks5
      port: 8388      # SOCKS5 proxy
---
# Client Pod
apiVersion: apps/v1
kind: Deployment
metadata:
  name: irc-bot
spec:
  template:
    spec:
      containers:
        - name: marmithon
          env:
            - name: HTTP_PROXY
              value: "http://vpn-proxy-iceland:8888"
            - name: HTTPS_PROXY
              value: "http://vpn-proxy-iceland:8888"
```

**Pros**:
- Multiple apps share single VPN connection
- Lower resource usage
- Easy to add more regions (vpn-proxy-netherlands, vpn-proxy-sweden, etc.)
- Apps can choose proxy via environment variable

**Cons**:
- Shared resource (one VPN connection for all)
- Single point of failure (mitigated by replicas)
- App must support HTTP/SOCKS5 proxy

### Pattern 3: Hybrid (Recommended)

**Use pattern 1 (sidecar) for**:
- Applications with high bandwidth (qbittorrent)
- Applications needing dedicated VPN connection
- Applications that don't support proxy configuration

**Use pattern 2 (shared proxy) for**:
- Low-bandwidth applications (IRC bot, API clients)
- Applications supporting HTTP/SOCKS5 proxy
- Services needing region selection flexibility

## Proposed Implementation for IRC Bot (marmithon)

### Step 1: Create Shared VPN Proxy Service

**Location**: `kubernetes/base/infra/network/vpn-proxy/`

**Files**:
```
vpn-proxy/
├── kustomization.yaml
├── namespace.yaml
├── deployment-iceland.yaml   # Primary exit point
├── deployment-netherlands.yaml  # Alternative region
├── service-iceland.yaml
├── service-netherlands.yaml
└── secrets.sops.yaml  # ProtonVPN credentials
```

**Key configuration** (`deployment-iceland.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vpn-proxy-iceland
  namespace: vpn-proxy
spec:
  replicas: 1  # Can scale for HA
  selector:
    matchLabels:
      app: vpn-proxy-iceland
  template:
    metadata:
      labels:
        app: vpn-proxy-iceland
    spec:
      containers:
        - name: gluetun
          image: ghcr.io/qdm12/gluetun:v3.40.1
          ports:
            - name: http-proxy
              containerPort: 8888
            - name: socks5
              containerPort: 8388
            - name: health
              containerPort: 9999
          env:
            - name: VPN_SERVICE_PROVIDER
              value: "protonvpn"
            - name: VPN_TYPE
              value: "wireguard"
            - name: SERVER_COUNTRIES
              value: "Iceland"
            - name: FIREWALL_OUTBOUND_SUBNETS
              value: "10.42.0.0/16,10.43.0.0/16"  # Allow K8s cluster
            - name: HTTPPROXY
              value: "on"
            - name: SHADOWSOCKS
              value: "on"
            - name: LOG_LEVEL
              value: "info"
            - name: HEALTH_SERVER_ADDRESS
              value: "0.0.0.0:9999"
          envFrom:
            - secretRef:
                name: vpn-proxy-protonvpn  # Shared across all ProtonVPN proxies
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 9999
            initialDelaySeconds: 60
            periodSeconds: 60
          readinessProbe:
            httpGet:
              path: /
              port: 9999
            initialDelaySeconds: 30
            periodSeconds: 30
```

### Step 2: Update IRC Bot to Use Proxy

**Location**: `kubernetes/base/apps/irc/marmithon/deployment.yaml`

**Option A: HTTP_PROXY environment variables** (if marmithon supports it)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: marmithon
  namespace: irc
spec:
  template:
    spec:
      containers:
        - name: marmithon
          image: forge.internal/nemo/marmitton:latest
          env:
            - name: HTTP_PROXY
              value: "http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888"
            - name: HTTPS_PROXY
              value: "http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888"
            - name: NO_PROXY
              value: "localhost,127.0.0.1,10.0.0.0/8"
```

**Option B: SOCKS5 proxy** (if marmithon needs SOCKS5)
```yaml
# Configure marmithon to use SOCKS5 proxy
# (depends on marmithon's proxy support)
env:
  - name: IRC_PROXY
    value: "socks5://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8388"
```

**Option C: Sidecar pattern** (if marmithon doesn't support proxy)
```yaml
# Fall back to sidecar if proxy not supported
# (similar to current qbittorrent setup)
```

### Step 3: Verification

**Test VPN is working**:
```bash
# From marmithon pod, check egress IP
kubectl exec -n irc deployment/marmithon -- curl ifconfig.me

# Should show ProtonVPN Iceland IP, not home IP
```

**Check proxy health**:
```bash
kubectl get pods -n vpn-proxy
kubectl logs -n vpn-proxy deployment/vpn-proxy-iceland
```

## VPN Provider Comparison

### ProtonVPN (Current for qbittorrent)
- **Pros**: Port forwarding, WireGuard, good privacy
- **Cons**: Requires paid plan for multiple connections
- **Cost**: €5-10/month depending on plan

### Mullvad VPN
- **Pros**: Anonymous (no account), €5/month flat, WireGuard
- **Cons**: No port forwarding (as of 2023)
- **Cost**: €5/month

### IVPN
- **Pros**: Strong privacy, port forwarding, WireGuard
- **Cons**: More expensive
- **Cost**: $6-10/month

### Recommendation
- **Stick with ProtonVPN** (already paying for it)
- Use same credentials across all gluetun instances
- ProtonVPN Plus plan allows multiple simultaneous connections

## Scaling Patterns

### Add New Region
```bash
# Copy deployment
cp deployment-iceland.yaml deployment-sweden.yaml

# Edit SERVER_COUNTRIES
sed -i 's/Iceland/Sweden/g' deployment-sweden.yaml

# Deploy
kubectl apply -f deployment-sweden.yaml -f service-sweden.yaml
```

### Add New Provider
```bash
# Create new secret for Mullvad
kubectl create secret generic vpn-proxy-mullvad \
  --from-literal=VPN_SERVICE_PROVIDER=mullvad \
  --from-literal=WIREGUARD_PRIVATE_KEY=... \
  --from-literal=WIREGUARD_ADDRESSES=...

# Deploy with Mullvad
# (change secretRef in deployment)
```

## Migration Plan from Tailscale Exit Node

### Phase 1: Deploy VPN Proxy Service ✓ (Already done for qbittorrent)
- [x] ProtonVPN credentials in SOPS
- [x] Gluetun deployment pattern validated
- [x] Health checks working

### Phase 2: Create Shared Proxy Infrastructure
- [ ] Create `kubernetes/base/infra/network/vpn-proxy/` namespace
- [ ] Deploy Iceland proxy (primary)
- [ ] Deploy Netherlands proxy (backup/alternative)
- [ ] Test proxy connectivity from test pod

### Phase 3: Migrate IRC Bot
- [ ] Determine if marmithon supports HTTP_PROXY or SOCKS5
- [ ] Update marmithon deployment with proxy configuration
- [ ] Test IRC connection shows VPN IP
- [ ] Monitor for stability (1 week)

### Phase 4: Cleanup
- [ ] Remove Tailscale Kubernetes Operator (if deployed)
- [ ] Decommission Hetzner VPS exit node
- [ ] Update documentation

### Phase 5: Future Enhancements
- [ ] Add more regions as needed (Sweden, Germany, etc.)
- [ ] Create NetworkPolicy to enforce VPN usage
- [ ] Add Prometheus metrics from gluetun
- [ ] Document per-app proxy selection pattern

## Cost Comparison

### Old Architecture (Tailscale Exit Node)
- VPS (Hetzner CAX11): €4.49/month
- **Total**: €53.88/year

### New Architecture (Gluetun Shared Proxy)
- ProtonVPN Plus: €5-10/month (already paying for qbittorrent)
- Additional cost: €0 (can reuse same VPN credentials)
- **Total**: €0 additional cost

**Savings**: €53.88/year + simplified architecture

## Security Considerations

### Network Policies
```yaml
# Enforce VPN usage for sensitive workloads
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: require-vpn-egress
  namespace: irc
spec:
  podSelector:
    matchLabels:
      requires-vpn: "true"
  policyTypes:
    - Egress
  egress:
    # Only allow egress to VPN proxy
    - to:
        - namespaceSelector:
            matchLabels:
              name: vpn-proxy
      ports:
        - port: 8888   # HTTP proxy
        - port: 8388   # SOCKS5 proxy
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - port: 53
          protocol: UDP
```

### Kill Switch
Gluetun includes built-in kill switch:
- If VPN connection drops, all traffic is blocked
- Only VPN traffic allowed through firewall
- No IP leaks possible

### IP Leak Testing
```bash
# Test from pod using VPN proxy
kubectl run -it --rm debug --image=curlimages/curl -- sh

# Inside pod
export HTTP_PROXY=http://vpn-proxy-iceland.vpn-proxy.svc.cluster.local:8888
curl ifconfig.me  # Should show VPN IP
curl -L https://ipleak.net/json/  # Check for leaks
```

## Monitoring and Alerts

### Metrics to Track
- VPN connection status (up/down)
- VPN server latency
- Proxy request rate
- Proxy error rate
- IP address changes

### Prometheus Integration
```yaml
# ServiceMonitor for gluetun metrics
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vpn-proxy
  namespace: vpn-proxy
spec:
  selector:
    matchLabels:
      app: vpn-proxy
  endpoints:
    - port: metrics
      interval: 30s
```

### Alerts
```yaml
# Alert if VPN proxy is down
groups:
  - name: vpn-proxy
    rules:
      - alert: VPNProxyDown
        expr: up{job="vpn-proxy"} == 0
        for: 5m
        annotations:
          summary: "VPN proxy {{ $labels.instance }} is down"
```

## References

- [Gluetun Documentation](https://github.com/qdm12/gluetun)
- [Gluetun Wiki](https://github.com/qdm12/gluetun-wiki)
- [ProtonVPN Configuration](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)
- Existing implementation: `kubernetes/base/apps/media/qbittorrent/deployment.yaml`
- Related docs: `tailscale-architecture-refactored.md` (mesh VPN for remote access)

---

*Created: 2025-12-14*
*Status*: 🚧 Planned - qbittorrent pattern proven, IRC bot migration pending
