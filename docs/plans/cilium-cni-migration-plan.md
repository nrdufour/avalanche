# Cilium CNI Migration Plan

**Status**: 🚧 Planning
**Created**: 2025-12-27
**Last Updated**: 2025-12-27
**Target Completion**: TBD

## Overview

This document outlines the plan to migrate the Avalanche K3s cluster from the default Flannel CNI to Cilium. Cilium provides advanced networking features including:

- eBPF-based networking for improved performance
- Advanced NetworkPolicy support with L7 filtering
- Hubble observability for network flows
- Service mesh capabilities without sidecars
- kube-proxy replacement mode
- Gateway API support

## Current State

### K3s Configuration
- **Version**: k3s 1.33 (nixos/modules/nixos/services/k3s/default.nix:10)
- **CNI**: Flannel (default, not explicitly disabled)
- **Controllers**: 3x Orange Pi 5 Plus (opi01-03, aarch64)
- **Workers**: 6x Raspberry Pi 4 (raccoon00-05, aarch64)
- **Network**: kube-vip VIP at 10.1.0.5
- **Pod CIDR**: 10.42.0.0/16 (k3s default)
- **Service CIDR**: 10.43.0.0/16 (k3s default)
- **GitOps**: ArgoCD (self-managed)

### Existing Network Features
- **NetworkPolicies**: Currently deployed
  - `kubernetes/base/apps/irc/marmithon/netpol.yaml` (egress restrictions)
  - `kubernetes/base/infra/security/bitwarden/netpol.yaml`
- **Disabled Components**: local-storage, traefik, metrics-server (nixos/modules/nixos/services/k3s/default.nix:67-69)
- **kube-proxy**: Enabled (default)

### ARM64-Specific Considerations

**IMPORTANT**: All nodes in this cluster are ARM64 (aarch64):

| Node Type | Hardware | Kernel | Cilium Compatibility |
|-----------|----------|--------|---------------------|
| Controllers (opi01-03) | Orange Pi 5 Plus (RK3588) | Linux 6.18 | ✅ Fully compatible |
| Workers (raccoon00-05) | Raspberry Pi 4 | NixOS default (~6.6+) | ✅ Fully compatible |

**Key ARM64 requirements for Cilium**:
- Minimum kernel 5.10 for basic functionality
- Minimum kernel 6.0 for multicast support on ARM64 (due to `bpf_jit_supports_subprog_tailcalls()`)
- Both hardware profiles exceed these requirements

**Reference**: [Cilium System Requirements](https://docs.cilium.io/en/stable/operations/system_requirements/)

### Existing Infrastructure Interactions

#### kube-vip (VIP: 10.1.0.5)
- Uses ARP mode with `hostNetwork: true`
- Runs only on control-plane nodes
- **Cilium Impact**: None expected - kube-vip operates at L2/L3 before Cilium CNI
- **Verification Required**: Ensure VIP remains accessible during migration

#### Longhorn (Storage)
- Uses iSCSI for block storage replication
- Requires pod-to-pod communication across nodes
- **Cilium Impact**: May require explicit NetworkPolicy allowing Longhorn traffic
- **Verification Required**: Test volume replication after Cilium deployment

#### Gluetun (VPN Egress)
- Used by qbittorrent and marmithon for VPN egress
- Runs as sidecar with `NET_ADMIN` capability
- **Cilium Impact**: Should work, but verify VPN tunnel establishment
- **Verification Required**: Confirm VPN connectivity post-migration

## Migration Strategy Options

### Option A: In-Place Migration with Controlled Rollout (Recommended)

We will use an **in-place migration** strategy that minimizes downtime:

1. **Prepare NixOS configuration** for Cilium compatibility
2. **Drain and deploy controllers** one at a time with Flannel disabled
3. **Install Cilium** via Helm before deploying NixOS changes
4. **Validate networking** on each controller
5. **Roll out to workers** one by one with proper draining
6. **Migrate workloads** progressively
7. **Enable advanced features** (kube-proxy replacement, Hubble)

**Pros**:
- Preserves PersistentVolumeClaims and stateful data (PostgreSQL, InfluxDB, etc.)
- No need to restore from backups
- Can validate at each step
- Supports progressive rollout

**Cons**:
- More complex than clean slate
- Requires careful sequencing
- Brief networking disruption per node during transition

### Option B: Cilium Migration Mode (Lower Risk, Longer Duration)

Cilium supports a [migration mode](https://docs.cilium.io/en/latest/installation/k8s-install-migration/) that allows running alongside the existing CNI:

1. **Install Cilium in migration mode** alongside Flannel
2. **Both CNIs handle different pods** temporarily
3. **Gradually transition pods** to Cilium
4. **Remove Flannel** after all pods migrated

**Pros**:
- Lower risk - can rollback easily
- No hard cutover moment
- Existing pods keep working

**Cons**:
- Longer migration window
- Two CNIs running simultaneously (resource overhead)
- More complex debugging if issues arise
- Requires Cilium `--enable-bpf-masquerade=false` initially

### Option C: Clean Rebuild (Highest Risk, Clean State)

Rebuild the entire cluster from scratch:

1. **Backup all data** (Longhorn snapshots, PostgreSQL dumps)
2. **Destroy existing cluster**
3. **Deploy fresh k3s with Cilium** from the start
4. **Restore data from backups**

**Pros**:
- Cleanest possible state
- No legacy CNI artifacts

**Cons**:
- Highest risk of data loss
- Longest downtime
- Most complex recovery if backup fails

### Decision: Option A (In-Place Migration)

**Rationale**:
- Preserves stateful data without backup/restore risk
- Cluster is small enough (9 nodes) for per-node rollout
- kube-vip HA provides API server availability during controller migration
- Progressive approach allows validation at each step

## Prerequisites

### Required Knowledge
- [ ] Review [Cilium k3s installation guide](https://docs.cilium.io/en/stable/installation/k3s/)
- [ ] Review [Cilium migration documentation](https://docs.cilium.io/en/latest/installation/k8s-install-migration/)
- [ ] Understand [k3s network options](https://docs.k3s.io/installation/network-options)
- [ ] Review [Cilium System Requirements](https://docs.cilium.io/en/stable/operations/system_requirements/)

### Infrastructure Requirements
- [ ] Backup critical data (PostgreSQL databases, Longhorn volumes)
- [ ] Ensure cluster has internet access (for Cilium installation)
- [ ] Verify all nodes are healthy and up-to-date
- [ ] Access to kubeconfig (via `just k8s get-kubeconfig`)
- [ ] SSH access to all k3s nodes via Tailscale
- [ ] Verify etcd cluster health (for HA controllers)
- [ ] Check PodDisruptionBudgets won't block node draining
- [ ] Schedule maintenance window (expect ~30min per node)

### Resource Requirements

**Cilium Agent (per node)**:
| Resource | Request | Limit | Notes |
|----------|---------|-------|-------|
| CPU | 100m | 4000m | eBPF compilation is CPU-intensive initially |
| Memory | 128Mi | 512Mi | May need more on workers with many pods |

**Cilium Operator (cluster-wide)**:
| Resource | Request | Limit | Notes |
|----------|---------|-------|-------|
| CPU | 100m | 1000m | Single replica sufficient |
| Memory | 128Mi | 512Mi | Manages CiliumEndpoints |

**Hubble Relay**:
| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 100m | 500m |
| Memory | 128Mi | 256Mi |

**Hubble UI**:
| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 50m | 200m |
| Memory | 64Mi | 128Mi |

**ARM SBC Considerations**:
- Orange Pi 5 Plus has 16GB RAM - sufficient headroom
- Raspberry Pi 4 has 4GB or 8GB RAM - monitor memory pressure
- Consider reducing Hubble buffer sizes on workers if memory constrained

### Tools Required
- [ ] `helm` CLI v3.x (for Cilium installation)
- [ ] `cilium` CLI v0.18.x (for validation and troubleshooting)
- [ ] `kubectl` with cluster access
- [ ] `hubble` CLI (optional, for flow observation)
- [ ] NixOS rebuild access to all k3s nodes

### Pre-Flight Checks
```bash
# Verify cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

# Check etcd health (on any controller)
ssh opi01.internal
sudo k3s etcd-snapshot ls
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health

# Check for PodDisruptionBudgets that might block draining
kubectl get pdb -A

# Verify kernel supports eBPF (should return 0)
ssh opi01.internal "zcat /proc/config.gz | grep CONFIG_BPF="

# Check available memory on workers
for node in raccoon00 raccoon01 raccoon02 raccoon03 raccoon04 raccoon05; do
  echo "=== $node ==="
  ssh $node.internal free -h
done
```

## Detailed Migration Steps

### Phase 1: Preparation (No Downtime)

#### 1.1 Backup Current State
```bash
# Backup cluster state
kubectl get all --all-namespaces -o yaml > cluster-backup-$(date +%Y%m%d).yaml

# Backup NetworkPolicies specifically
kubectl get networkpolicies --all-namespaces -o yaml > netpol-backup-$(date +%Y%m%d).yaml

# Backup ArgoCD applications
kubectl get applications -n argocd -o yaml > argocd-apps-backup-$(date +%Y%m%d).yaml

# Verify Longhorn backups are current
kubectl get backups -n longhorn-system
```

#### 1.2 Document Current Network State
```bash
# Check current pod networking
kubectl get pods -A -o wide > pods-before-migration.txt

# Check services
kubectl get svc -A -o wide > services-before-migration.txt

# Test internal connectivity
kubectl run test-pod --image=nicolaka/netshoot --rm -it -- /bin/bash
# Inside pod, test DNS and connectivity
# nslookup kubernetes.default
# curl http://<service>.<namespace>.svc.cluster.local
```

#### 1.3 Install Required Tools
```bash
# Install Helm (if not already available)
nix-shell -p kubernetes-helm

# Install Cilium CLI
nix-shell -p cilium-cli

# Verify installations
helm version
cilium version
```

### Phase 2: NixOS Configuration Changes

#### 2.1 Modify K3s Module Configuration

Update `nixos/modules/nixos/services/k3s/default.nix`:

**Add CNI configuration option** in the options block (around line 20):
```nix
disableDefaultCNI = mkOption {
  description = "Disable the default CNI (flannel) and network policy controller to use a custom CNI like Cilium";
  default = false;
  type = types.bool;
};
```

**Modify extraFlags section** (around line 62-91) to conditionally disable flannel AND the built-in network policy controller:
```nix
extraFlags = (if cfg.role == "agent"
  then
    # Agents don't need CNI flags - they get CNI config from server
    ""
  else toString ([
    # Disable useless services
    "--disable=local-storage"
    "--disable=traefik"
    "--disable=metrics-server"
  ]
  # Disable flannel and k3s network policy if custom CNI requested
  ++ lib.optionals cfg.disableDefaultCNI [
    "--flannel-backend=none"
    "--disable-network-policy"  # IMPORTANT: Let Cilium handle NetworkPolicy
  ]
  ++ [
    # virtual IP and its name
    "--tls-san opi01.internal"
    # ... rest of existing flags
  ])) + cfg.additionalFlags;
```

**Why `--disable-network-policy`?**
- k3s includes a built-in network policy controller (kube-router)
- Cilium provides its own NetworkPolicy implementation
- Running both causes conflicts and unexpected behavior
- Must disable k3s network policy to let Cilium enforce policies

#### 2.2 Update Controller Profile

Update `nixos/profiles/role-k3s-controller.nix`:
```nix
{
  # For now ...
  networking.firewall = {
    enable = false;
  };

  sops.defaultSopsFile = ../../secrets/k3s-worker/secrets.sops.yaml;

  mySystem = {
    services.k3s = {
      enable = true;
      role = "server";
      disableDefaultCNI = true;  # NEW: Disable flannel for Cilium
    };
  };

  # Network sysctl tuning for K3s controller nodes
  # ... rest of configuration
}
```

#### 2.3 Update Worker Profile

Update `nixos/profiles/role-k3s-worker.nix`:
```nix
{
  # For now ...
  networking.firewall = {
    enable = false;
  };

  sops.defaultSopsFile = ../../secrets/k3s-worker/secrets.sops.yaml;

  mySystem = {
    services.k3s = {
      enable = true;
      role = "agent";
      disableDefaultCNI = true;  # NEW: Disable flannel for Cilium
    };
  };

  # Network sysctl tuning for K3s worker nodes
  # ... rest of configuration
}
```

#### 2.4 Additional Kernel Requirements for Cilium

Cilium requires specific kernel features. Add to both controller and worker profiles:
```nix
# Enable required kernel modules for Cilium
boot.kernelModules = [
  "xt_socket"
  "xt_mark"
  "xt_conntrack"
  "br_netfilter"
  "overlay"
];

# Cilium-specific sysctl tuning
boot.kernel.sysctl = {
  # ... existing sysctl config ...

  # Cilium requirements
  "net.ipv4.conf.all.forwarding" = 1;
  "net.bridge.bridge-nf-call-iptables" = 1;
  "net.ipv4.ip_forward" = 1;
};
```

### Phase 3: Deploy NixOS Changes (Controlled Downtime)

⚠️ **WARNING**: This phase will cause networking disruption. Plan for maintenance window.

#### 3.1 Deploy to First Controller (opi01)

```bash
# Build locally first to verify
nix build .#nixosConfigurations.opi01.config.system.build.toplevel

# Deploy to opi01 (this will restart k3s)
just nix deploy opi01

# Monitor the deployment
ssh opi01.internal
sudo journalctl -u k3s -f
```

Expected behavior:
- k3s will start but pods will be in `Pending` or `ContainerCreating` state
- No CNI is available yet, so pod networking won't work
- API server should still be accessible

#### 3.2 Verify k3s Configuration

```bash
# SSH to opi01
ssh opi01.internal

# Verify flannel is disabled in k3s configuration
sudo cat /etc/systemd/system/k3s.service | grep flannel-backend

# Should show: --flannel-backend=none

# Check k3s is running
sudo systemctl status k3s
```

### Phase 4: Install Cilium

#### 4.1 Add Cilium to ArgoCD

Create `kubernetes/base/infra/network/cilium/` directory structure:

**File**: `kubernetes/base/infra/network/cilium-app.yaml`

This uses ArgoCD's multi-source feature to deploy Helm charts with custom values (same pattern as ingress-nginx, longhorn, etc.):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
  namespace: argocd
  # Ensure Cilium syncs before other apps that depend on networking
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: default
  sources:
    # Reference to values file in git repo
    - repoURL: https://forge.internal/nemo/avalanche.git
      targetRevision: HEAD
      ref: values
    # Cilium Helm chart
    - chart: cilium
      repoURL: https://helm.cilium.io
      # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
      targetRevision: 1.16.11  # Latest stable as of Dec 2025
      helm:
        releaseName: cilium
        valueFiles:
          - $values/kubernetes/base/infra/network/cilium/helm-values.yaml
  destination:
    namespace: cilium
    name: 'in-cluster'
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    automated:
      prune: true
      selfHeal: true
```

**File**: `kubernetes/base/infra/network/cilium/helm-values.yaml`

```yaml
# K3s specific configuration
k8sServiceHost: "10.1.0.5"  # kube-vip VIP
k8sServicePort: 6443

# IPAM configuration matching k3s defaults
ipam:
  mode: kubernetes
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"

# Keep kube-proxy initially (can enable replacement later)
kubeProxyReplacement: false

# Enable Hubble for observability
hubble:
  enabled: true
  relay:
    enabled: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
  ui:
    enabled: true
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi

# Operator configuration
operator:
  replicas: 1
  rollOutPods: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 1000m
      memory: 512Mi

# Agent resource configuration (important for ARM SBCs)
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 4000m
    memory: 512Mi

# BPF configuration
bpf:
  # Mount BPF filesystem (required)
  autoMount:
    enabled: true
  # Enable masquerading (NAT for pod-to-external traffic)
  masquerade: true

# Enable native routing mode (better performance than tunnel)
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: "10.0.0.0/8"

# Ensure agents run on control-plane nodes too
tolerations:
  - operator: Exists
    effect: NoSchedule

# Node selector: none (run on all nodes)
affinity: {}

# Disable unused features to reduce resource usage
envoy:
  enabled: false

# Gateway API (disabled for now, enable later if needed)
gatewayAPI:
  enabled: false

# Enable metrics for Prometheus
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

**File**: `kubernetes/base/infra/network/cilium/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
# Note: The Helm chart is deployed directly via ArgoCD Application
# This kustomization exists for potential future resources (e.g., CiliumNetworkPolicies)
```

**Update** `kubernetes/base/infra/network/kustomization.yaml` to include Cilium:

```yaml
resources:
  # ... existing resources
  - cilium-app.yaml
```

#### 4.2 Manual Cilium Installation (Alternative/Bootstrap)

If ArgoCD is disrupted during migration OR during initial cluster bootstrap, install manually:

```bash
# Add Cilium Helm repo
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium with production settings
helm install cilium cilium/cilium \
  --version 1.16.11 \
  --namespace cilium \
  --create-namespace \
  --set k8sServiceHost=10.1.0.5 \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set ipam.operator.clusterPoolIPv4PodCIDRList[0]=10.42.0.0/16 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set kubeProxyReplacement=false \
  --set operator.replicas=1 \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
  --set bpf.autoMount.enabled=true \
  --set bpf.masquerade=true \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true

# IMPORTANT: After cluster stabilizes, import into ArgoCD
# by syncing the cilium-app.yaml Application
```

**Note**: The manual installation should match `helm-values.yaml` settings to avoid drift when ArgoCD takes over management.

#### 4.3 Wait for Cilium Deployment

```bash
# Watch Cilium pods come up
kubectl get pods -n cilium -w

# Expected pods:
# - cilium-operator-<hash>
# - cilium-<hash> (one per node, DaemonSet)
# - hubble-relay-<hash>
# - hubble-ui-<hash>

# Check Cilium status
cilium status --wait

# Should show:
# - Cluster connectivity: OK
# - Hubble: OK
# - Operator: OK
```

### Phase 5: Validate Networking on Controllers

#### 5.1 Verify Pod Networking

```bash
# Deploy test pods
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-1
  namespace: default
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-2
  namespace: default
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
EOF

# Wait for pods to be Running
kubectl wait --for=condition=Ready pod/test-pod-1 pod/test-pod-2 --timeout=120s

# Test pod-to-pod connectivity
kubectl exec test-pod-1 -- ping -c 3 $(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}')

# Test DNS resolution
kubectl exec test-pod-1 -- nslookup kubernetes.default

# Test service connectivity
kubectl exec test-pod-1 -- curl -s http://kubernetes.default.svc.cluster.local:443 -k

# Clean up
kubectl delete pod test-pod-1 test-pod-2
```

#### 5.2 Check Existing Workloads

```bash
# List pods that might still be stuck
kubectl get pods -A | grep -E 'Pending|ContainerCreating|CrashLoopBackOff'

# For any stuck pods, try recreating them
# Example: restart ArgoCD
kubectl rollout restart deployment -n argocd

# Watch rollout
kubectl rollout status deployment -n argocd --watch
```

#### 5.3 Verify NetworkPolicies

```bash
# Check that NetworkPolicies are recognized
kubectl get networkpolicies -A

# Verify enforcement (Cilium should enforce by default)
cilium status | grep -i "Network Policy"

# Test specific NetworkPolicy (marmithon egress restriction)
kubectl exec -n irc deployment/marmitton -- curl -m 5 http://10.1.0.5:6443 -k
# Should fail with timeout (egress to 10.0.0.0/8 blocked)

kubectl exec -n irc deployment/marmitton -- curl -m 5 http://irc.libera.chat
# Should succeed (egress to internet allowed)
```

### Phase 6: Roll Out to Remaining Controllers

#### 6.1 Deploy to opi02

```bash
# Build and deploy
just nix deploy opi02

# Watch Cilium agent start
ssh opi02.internal
sudo journalctl -u k3s -f

# Verify Cilium connectivity
cilium status

# Check node joined cluster
kubectl get nodes
```

#### 6.2 Deploy to opi03

```bash
# Build and deploy
just nix deploy opi03

# Verify
ssh opi03.internal
sudo journalctl -u k3s -f

# Verify Cilium connectivity
cilium status

# Check all controllers are Ready
kubectl get nodes -l node-role.kubernetes.io/control-plane
```

### Phase 7: Roll Out to Workers

#### 7.1 Deploy to Workers One-by-One

**Strategy**: Drain, deploy, and uncordon each worker, waiting for stability before proceeding.

⚠️ **IMPORTANT**: Proper draining prevents workload disruption and ensures pods are rescheduled gracefully.

```bash
# Function to migrate a single worker node
migrate_worker() {
  local node=$1
  echo "=== Migrating $node ==="

  # Step 1: Cordon the node (prevent new pods)
  echo "Cordoning $node..."
  kubectl cordon $node

  # Step 2: Drain the node (evict pods gracefully)
  echo "Draining $node..."
  kubectl drain $node \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=300s

  # Step 3: Deploy NixOS changes
  echo "Deploying NixOS to $node..."
  just nix deploy $node

  # Step 4: Wait for k3s to restart and node to be Ready
  echo "Waiting for $node to be Ready..."
  sleep 30  # Give k3s time to restart
  kubectl wait --for=condition=Ready node/$node --timeout=300s

  # Step 5: Verify Cilium agent is running on this node
  echo "Verifying Cilium agent on $node..."
  kubectl wait --for=condition=Ready -n cilium pod -l k8s-app=cilium --field-selector spec.nodeName=$node --timeout=120s

  # Step 6: Uncordon the node (allow scheduling)
  echo "Uncordoning $node..."
  kubectl uncordon $node

  # Step 7: Quick connectivity test
  echo "Running connectivity test..."
  cilium connectivity test --test-namespace cilium-test --single-node --node $node || true

  echo "=== $node migration complete ==="
  echo ""
}

# Migrate raccoon00 first and verify thoroughly
migrate_worker raccoon00

# Verify cluster health before continuing
kubectl get nodes
kubectl get pods -A | grep -v Running

# If healthy, continue with remaining workers
# Consider doing 2 at a time if time-constrained
for node in raccoon01 raccoon02 raccoon03 raccoon04 raccoon05; do
  migrate_worker $node
  # Brief pause between nodes to let cluster stabilize
  sleep 60
done
```

#### 7.2 Handle Longhorn During Draining

Longhorn volumes need special consideration during node draining:

```bash
# Before draining a node, check for Longhorn volumes
kubectl get volumes.longhorn.io -A -o wide | grep $node

# If volumes are attached, ensure replicas exist on other nodes
kubectl get replicas.longhorn.io -A -o wide | grep $node

# Longhorn should automatically rebuild replicas on other nodes
# Monitor in Longhorn UI: https://longhorn.internal (if exposed)
```

#### 7.3 Verify Full Cluster Connectivity

```bash
# Run comprehensive Cilium connectivity test
cilium connectivity test

# This will:
# - Create test pods on multiple nodes
# - Test pod-to-pod connectivity across nodes
# - Test service discovery
# - Test NetworkPolicy enforcement
# - Test host reachability

# Expected: All tests should PASS
```

### Phase 8: Migrate Workloads and Validate

#### 8.1 Restart Critical Workloads

```bash
# Restart workloads that were running during migration
# This ensures they get fresh network configuration

# ArgoCD
kubectl rollout restart deployment -n argocd
kubectl rollout status deployment -n argocd --watch

# Nginx Ingress Controller
kubectl rollout restart deployment -n network ingress-nginx-controller
kubectl rollout status deployment -n network ingress-nginx-controller --watch

# Longhorn (carefully, one component at a time)
kubectl rollout restart deployment -n longhorn-system longhorn-driver-deployer
kubectl rollout restart deployment -n longhorn-system longhorn-ui

# Wait for Longhorn to stabilize
kubectl get pods -n longhorn-system -w
```

#### 8.2 Validate Application Connectivity

Test critical applications:

```bash
# Test internal service discovery
kubectl run test-curl --image=curlimages/curl --rm -it -- /bin/sh
# Inside pod:
# curl http://homepage.self-hosted.svc.cluster.local
# curl http://miniflux.self-hosted.svc.cluster.local

# Test ingress (from external)
curl -k https://homepage.internal  # Via Tailscale
curl -k https://miniflux.internal

# Test specific apps with NetworkPolicies
# Marmithon IRC bot (has egress restrictions)
kubectl logs -n irc deployment/marmitton --tail=50
# Should show successful IRC connections

# Vaultwarden (has ingress restrictions)
kubectl exec -n security deployment/vaultwarden -- wget -O- http://localhost:80
```

#### 8.3 Check Prometheus/Grafana Metrics

```bash
# Verify metrics collection is working
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# In browser: http://localhost:9090
# Query: up{job="kubelet"}
# Should show all nodes

# Check Grafana dashboards
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Verify:
# - K8s / Networking / Pod Total dashboard
# - Node exporter dashboard
```

### Phase 9: Enable Hubble Observability

#### 9.1 Access Hubble UI

```bash
# Port-forward Hubble UI
cilium hubble port-forward &

# Or via kubectl
kubectl port-forward -n cilium svc/hubble-ui 12000:80

# Access in browser: http://localhost:12000
```

#### 9.2 Use Hubble CLI

```bash
# Install Hubble CLI (if not already)
nix-shell -p hubble

# Port-forward Hubble Relay
cilium hubble port-forward &

# Watch live network flows
hubble observe

# Filter flows
hubble observe --namespace irc
hubble observe --pod marmitton

# Check dropped packets (NetworkPolicy enforcement)
hubble observe --verdict DROPPED

# Get flow statistics
hubble status
```

### Phase 10: Update Bootstrap Process

#### 10.1 Modify Bootstrap Command

The current bootstrap command in `.justfiles/k8s.just` references FluxCD and has incorrect paths. Update it for Cilium + ArgoCD:

**Replace the entire bootstrap recipe** (around line 33-68):

```just
# renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
prometheus_operator_version := "v0.80.0"

# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
cilium_version := "1.16.11"

# Bootstrap ArgoCD on a cluster (default: main)
# Prerequisites:
# - k3s running with --flannel-backend=none --disable-network-policy
# - SOPS_AGE_KEY_FILE environment variable set
bootstrap cluster="main":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check precondition: SOPS_AGE_KEY_FILE must exist
    if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
        echo "Error: SOPS_AGE_KEY_FILE not found at $SOPS_AGE_KEY_FILE"
        exit 1
    fi

    echo "=== Phase 1: Install Cilium CNI ==="
    # Cilium must be installed FIRST - pods can't schedule without a CNI
    if ! helm repo list | grep -q cilium; then
        helm repo add cilium https://helm.cilium.io/
    fi
    helm repo update cilium

    helm upgrade --install cilium cilium/cilium \
      --version {{cilium_version}} \
      --namespace cilium \
      --create-namespace \
      --set k8sServiceHost=10.1.0.5 \
      --set k8sServicePort=6443 \
      --set ipam.mode=kubernetes \
      --set ipam.operator.clusterPoolIPv4PodCIDRList[0]=10.42.0.0/16 \
      --set hubble.enabled=true \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --set kubeProxyReplacement=false \
      --set operator.replicas=1 \
      --set routingMode=native \
      --set autoDirectNodeRoutes=true \
      --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
      --set bpf.autoMount.enabled=true \
      --set bpf.masquerade=true \
      --set prometheus.enabled=true \
      --set prometheus.serviceMonitor.enabled=true

    echo "Waiting for Cilium to be ready..."
    kubectl wait --for=condition=Ready -n cilium pod -l k8s-app=cilium --timeout=300s

    echo "=== Phase 2: Install Prometheus Operator CRDs ==="
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusagents.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml

    echo "=== Phase 3: Install ArgoCD ==="
    kubectl --context {{cluster}} apply --server-side --force-conflicts \
      --kustomize {{kubernetes_dir}}/bootstrap

    echo "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=Ready -n argocd pod -l app.kubernetes.io/name=argocd-server --timeout=300s

    echo "=== Phase 4: Apply ArgoCD Secrets ==="
    sops --decrypt {{kubernetes_dir}}/clusters/{{cluster}}/secrets/argocd-repo.sops.yaml | \
      kubectl --context {{cluster}} apply --server-side --filename -
    sops --decrypt {{kubernetes_dir}}/clusters/{{cluster}}/secrets/sops-age.sops.yaml | \
      kubectl --context {{cluster}} apply --server-side --filename -

    echo "=== Phase 5: Deploy Cluster App-of-Apps ==="
    kubectl --context {{cluster}} apply --server-side \
      --filename {{kubernetes_dir}}/clusters/{{cluster}}/cluster.yaml

    echo ""
    echo "=== Bootstrap Complete! ==="
    echo "ArgoCD will now sync all applications from git."
    echo "Monitor progress: argocd app list"
    echo "Cilium status: cilium status"
```

**Note**: You'll need to create/update the secrets paths. The current bootstrap references incorrect paths (`kubernetes/kubernetes/{{cluster}}/...`).

#### 10.2 Update Bootstrap Kustomization

The bootstrap kustomization (`kubernetes/bootstrap/kustomization.yaml`) is fine as-is. It references ArgoCD which will then manage Cilium via the `cilium-app.yaml`.

**No changes needed** - Cilium is installed via Helm during bootstrap, then ArgoCD takes over management.

#### 10.3 Clean Up Old FluxCD References

After migration, remove any remaining FluxCD references:

```bash
# Search for FluxCD references in kubernetes/
grep -r "flux" kubernetes/ --include="*.yaml" --include="*.md"

# Remove any FluxCD-specific directories or files
# (after verifying they're not needed)
```

### Phase 11: Advanced Features (Optional)

#### 11.1 Enable kube-proxy Replacement

⚠️ **Do this only after verifying base Cilium functionality**

**Benefits**:
- Improved performance (eBPF replaces iptables)
- Better scalability
- Direct server return (DSR)

**Update Cilium configuration** to enable:
```yaml
# In kubernetes/base/infra/network/cilium/helmrelease.yaml
values:
  kubeProxyReplacement: true
  k8sServiceHost: 10.1.0.5
  k8sServicePort: 6443
```

**Validate**:
```bash
# Check kube-proxy replacement status
cilium status | grep -i "KubeProxyReplacement"

# Should show: Enabled

# Run connectivity tests
cilium connectivity test --test kube-proxy-replacement
```

#### 11.2 Enable Gateway API

For future ingress consolidation:

```yaml
# In kubernetes/base/infra/network/cilium/helmrelease.yaml
values:
  gatewayAPI:
    enabled: true
```

Then install Gateway API CRDs:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

## Testing and Validation

### Test Scenarios

#### 1. Pod Connectivity Test
```bash
# Create test deployment across multiple nodes
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connectivity-test
  namespace: default
spec:
  replicas: 6  # One per worker node
  selector:
    matchLabels:
      app: connectivity-test
  template:
    metadata:
      labels:
        app: connectivity-test
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: connectivity-test
            topologyKey: kubernetes.io/hostname
      containers:
      - name: netshoot
        image: nicolaka/netshoot
        command: ["sleep", "3600"]
---
apiVersion: v1
kind: Service
metadata:
  name: connectivity-test
  namespace: default
spec:
  selector:
    app: connectivity-test
  ports:
  - port: 80
    targetPort: 8080
EOF

# Wait for all pods
kubectl wait --for=condition=Ready pod -l app=connectivity-test --timeout=120s

# Test connectivity between all pods
for pod in $(kubectl get pods -l app=connectivity-test -o name); do
  echo "Testing from $pod"
  kubectl exec $pod -- ping -c 2 connectivity-test.default.svc.cluster.local
done

# Cleanup
kubectl delete deployment connectivity-test
kubectl delete service connectivity-test
```

#### 2. NetworkPolicy Enforcement Test
```bash
# Create test namespace
kubectl create namespace netpol-test

# Deploy server pod
kubectl run server -n netpol-test --image=nginx --labels=app=server --expose --port=80

# Deploy client pod (allowed)
kubectl run client-allowed -n netpol-test --image=nicolaka/netshoot --labels=app=client-allowed --command -- sleep 3600

# Deploy client pod (denied)
kubectl run client-denied -n netpol-test --image=nicolaka/netshoot --labels=app=client-denied --command -- sleep 3600

# Create NetworkPolicy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: server-policy
  namespace: netpol-test
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: client-allowed
EOF

# Test allowed connectivity (should succeed)
kubectl exec -n netpol-test client-allowed -- curl -m 5 http://server

# Test denied connectivity (should timeout)
kubectl exec -n netpol-test client-denied -- curl -m 5 http://server
# Expected: timeout after 5s

# View in Hubble
hubble observe --namespace netpol-test --verdict DROPPED

# Cleanup
kubectl delete namespace netpol-test
```

#### 3. Hubble Observability Test
```bash
# Port-forward Hubble UI
kubectl port-forward -n cilium svc/hubble-ui 12000:80 &

# Generate some traffic
kubectl run test-curl --image=curlimages/curl --rm -it -- sh -c "while true; do curl -s http://kubernetes.default.svc.cluster.local:443 -k; sleep 2; done"

# In Hubble UI (http://localhost:12000):
# - Select namespace: default
# - Should see flows from test-curl pod to kubernetes service
# - View service map showing connectivity

# CLI observation
hubble observe --namespace default --follow

# Stop port-forward
pkill -f "port-forward.*hubble-ui"
```

#### 4. Cross-Node Communication Test
```bash
# Get two nodes
NODE1=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE2=$(kubectl get nodes -o jsonpath='{.items[1].metadata.name}')

# Deploy pod on NODE1
kubectl run test-node1 --image=nginx --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'$NODE1'"}}}'

# Deploy pod on NODE2
kubectl run test-node2 --image=nicolaka/netshoot --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'$NODE2'"}}}' --command -- sleep 3600

# Wait for ready
kubectl wait --for=condition=Ready pod/test-node1 pod/test-node2 --timeout=120s

# Test connectivity from NODE2 to NODE1
POD1_IP=$(kubectl get pod test-node1 -o jsonpath='{.status.podIP}')
kubectl exec test-node2 -- curl -m 5 http://$POD1_IP

# Cleanup
kubectl delete pod test-node1 test-node2
```

### Expected Outcomes

After successful migration:

✅ **Cluster Health**:
- All nodes show `Ready` status
- All Cilium agents running (one per node)
- No `CrashLoopBackOff` or `Pending` pods

✅ **Networking**:
- Pod-to-pod connectivity works across nodes
- Service discovery via DNS works
- Ingress traffic reaches applications
- NetworkPolicies are enforced

✅ **Observability**:
- Hubble UI accessible and showing flows
- `cilium status` reports healthy
- Prometheus metrics include Cilium endpoints

✅ **Applications**:
- ArgoCD syncing successfully
- All applications responding to health checks
- No connectivity errors in application logs
- Ingress URLs accessible via Tailscale

### Performance Metrics

Monitor these before and after migration:

```bash
# Network latency (pod-to-pod)
kubectl run perf-test --image=nicolaka/netshoot --rm -it -- ping -c 100 <target-pod-ip>
# Compare avg latency before/after

# Throughput test
kubectl run iperf-server --image=networkstatic/iperf3 --port=5201 --expose --command -- iperf3 -s
kubectl run iperf-client --image=networkstatic/iperf3 --rm -it -- iperf3 -c iperf-server
# Compare throughput before/after

# Check kube-proxy replacement impact (if enabled)
# Measure service response times
time kubectl run test --image=curlimages/curl --rm -it -- curl http://kubernetes.default.svc.cluster.local:443 -k
```

## Rollback Procedure

If migration fails, rollback to Flannel:

### Option 1: Quick Rollback (within maintenance window)

```bash
# 1. Remove Cilium
kubectl delete namespace cilium

# 2. Revert NixOS configuration
# In nixos/profiles/role-k3s-controller.nix and role-k3s-worker.nix:
# Set disableDefaultCNI = false;

# 3. Deploy configuration to all nodes
just nix deploy-all

# 4. Wait for Flannel to reinitialize
kubectl get pods -A -w

# 5. Verify connectivity
kubectl run test --image=nicolaka/netshoot --rm -it -- ping 8.8.8.8
```

### Option 2: Full Rollback (restore from backup)

```bash
# 1. Restore cluster state
kubectl apply -f cluster-backup-<date>.yaml

# 2. Verify critical applications
kubectl get pods -A

# 3. Restore data from Longhorn backups if needed
kubectl get backups -n longhorn-system
# Use Longhorn UI to restore specific volumes
```

## Post-Migration Cleanup

### Remove Flannel Artifacts

After successful migration and validation, clean up Flannel remnants:

```bash
# 1. Remove Flannel CNI configuration files (on each node)
for node in opi01 opi02 opi03 raccoon00 raccoon01 raccoon02 raccoon03 raccoon04 raccoon05; do
  echo "=== Cleaning $node ==="
  ssh $node.internal "sudo rm -f /etc/cni/net.d/10-flannel.conflist"
  ssh $node.internal "sudo rm -rf /run/flannel"
done

# 2. Remove Flannel network interface (if present)
for node in opi01 opi02 opi03 raccoon00 raccoon01 raccoon02 raccoon03 raccoon04 raccoon05; do
  ssh $node.internal "sudo ip link delete flannel.1 2>/dev/null || true"
  ssh $node.internal "sudo ip link delete cni0 2>/dev/null || true"
done

# 3. Clean up iptables rules left by Flannel (optional, reboot clears these)
# Be careful - only run if you understand the implications
# ssh $node.internal "sudo iptables -F FLANNEL-FWD 2>/dev/null || true"
```

### Verify Clean State

```bash
# Check no Flannel interfaces remain
for node in opi01 opi02 opi03; do
  echo "=== $node interfaces ==="
  ssh $node.internal "ip link show | grep -E 'flannel|cni0'"
done

# Check Cilium is the only CNI
for node in opi01 opi02 opi03; do
  echo "=== $node CNI configs ==="
  ssh $node.internal "ls -la /etc/cni/net.d/"
done
# Should only show Cilium's CNI config (05-cilium.conflist or similar)
```

## Troubleshooting

### Issue: Cilium Pods Not Starting

**Symptoms**:
```
cilium-xxxxx   0/1   CrashLoopBackOff
```

**Diagnosis**:
```bash
kubectl logs -n cilium cilium-xxxxx
kubectl describe pod -n cilium cilium-xxxxx

# Check for eBPF errors
ssh opi01.internal "dmesg | grep -i bpf | tail -20"
```

**Common causes**:
- Missing kernel modules: Check `boot.kernelModules` in NixOS config
- Incorrect k8sServiceHost: Should be 10.1.0.5 (kube-vip VIP)
- Firewall blocking: Ensure firewall disabled on k3s nodes
- BPF filesystem not mounted: Check `mount | grep bpf`

**ARM64-specific issues**:
- Kernel too old for eBPF features: Ensure kernel 6.0+ for full ARM64 support
- Missing eBPF JIT: Check `cat /proc/sys/net/core/bpf_jit_enable` (should be 1 or 2)

### Issue: Pods Stuck in ContainerCreating

**Symptoms**:
```
my-pod   0/1   ContainerCreating
```

**Diagnosis**:
```bash
kubectl describe pod my-pod
# Look for CNI-related errors

# Check Cilium endpoint
kubectl get cep -A  # CiliumEndpoint
```

**Resolution**:
- Verify Cilium agents running on pod's node
- Delete and recreate pod
- Check node's Cilium agent logs: `kubectl logs -n cilium cilium-<node> -f`

### Issue: NetworkPolicy Not Enforced

**Symptoms**: Connections succeed that should be blocked

**Diagnosis**:
```bash
# Check if Cilium is enforcing
cilium status | grep "Policy Enforcement"

# Check NetworkPolicy in Cilium format
kubectl get cnp -A  # CiliumNetworkPolicy

# View policy verdict in Hubble
hubble observe --verdict DROPPED
```

**Resolution**:
- Ensure NetworkPolicy has correct labels
- Verify pod labels match policy selectors
- Check for conflicting policies

### Issue: DNS Resolution Failing

**Symptoms**:
```bash
kubectl exec test-pod -- nslookup kubernetes.default
# Error: server can't find kubernetes.default
```

**Diagnosis**:
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check Cilium DNS proxy
cilium config view | grep dns-proxy

# Test DNS from host
ssh opi01.internal "nslookup kubernetes.default.svc.cluster.local 10.43.0.10"
```

**Resolution**:
- Restart CoreDNS: `kubectl rollout restart deployment -n kube-system coredns`
- Verify service CIDR: Should be 10.43.0.0/16
- Check if DNS service exists: `kubectl get svc -n kube-system kube-dns`

### Issue: kube-vip VIP Not Accessible After Migration

**Symptoms**:
- `kubectl` commands timeout
- Cannot reach 10.1.0.5:6443

**Diagnosis**:
```bash
# Check kube-vip pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-vip

# Check if VIP is bound (from any controller)
ssh opi01.internal "ip addr show | grep 10.1.0.5"

# Check ARP table
ssh opi01.internal "arp -n | grep 10.1.0.5"
```

**Resolution**:
- kube-vip uses hostNetwork and should be unaffected by Cilium
- Restart kube-vip pods: `kubectl rollout restart daemonset -n kube-system kube-vip`
- Check that Cilium hasn't blocked ARP (unlikely with default config)

### Issue: Longhorn Volumes Not Replicating

**Symptoms**:
- Longhorn UI shows degraded volumes
- Replicas stuck in "Rebuilding"

**Diagnosis**:
```bash
# Check Longhorn manager pods
kubectl get pods -n longhorn-system -l app=longhorn-manager

# Check iSCSI connectivity between nodes
kubectl logs -n longhorn-system -l app=longhorn-manager | grep -i "error\|failed"

# Verify iSCSI ports are accessible
ssh raccoon00.internal "nc -zv raccoon01.internal 3260"
```

**Resolution**:
- Ensure Cilium allows iSCSI traffic (port 3260)
- May need CiliumNetworkPolicy to allow Longhorn namespace traffic:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-longhorn
  namespace: longhorn-system
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": longhorn-system
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": longhorn-system
```

### Issue: Gluetun VPN Tunnel Not Establishing

**Symptoms**:
- qbittorrent can't connect to trackers
- marmithon IRC bot disconnects

**Diagnosis**:
```bash
# Check Gluetun logs
kubectl logs -n media deployment/qbittorrent -c gluetun

# Verify tun device works
kubectl exec -n media deployment/qbittorrent -c gluetun -- ip link show tun0
```

**Resolution**:
- Gluetun needs `NET_ADMIN` capability (should already be configured)
- Ensure `tun` device is available in container
- Cilium should not interfere with VPN tunnels inside pods

### Issue: Partial Connectivity Between Nodes

**Symptoms**:
- Some pods can reach each other, others can't
- Cross-node communication fails

**Diagnosis**:
```bash
# Run Cilium connectivity test
cilium connectivity test --test pod-to-pod

# Check Cilium health on all nodes
cilium status

# Check for routing issues
cilium bpf tunnel list

# Check CiliumEndpoint status
kubectl get cep -A | grep -v "ready"
```

**Resolution**:
- Verify native routing mode is working: `cilium config view | grep routing-mode`
- Check for MTU issues (especially on Tailscale): Cilium default MTU might conflict
- Restart Cilium agents on affected nodes: `kubectl delete pod -n cilium -l k8s-app=cilium --field-selector spec.nodeName=<node>`

## Post-Migration Tasks

### Documentation Updates

- [ ] Update network architecture diagram to show Cilium
- [ ] Document Hubble UI access procedure
- [ ] Add Cilium troubleshooting guide to docs/troubleshooting/
- [ ] Update CLAUDE.md with Cilium information

### Monitoring Setup

- [ ] Add Cilium Grafana dashboards
- [ ] Configure alerts for Cilium agent failures
- [ ] Set up Hubble metrics in Prometheus
- [ ] Create runbook for common Cilium issues

### Future Enhancements

- [ ] Migrate to kube-proxy replacement mode (if not done)
- [ ] Enable Gateway API for ingress consolidation
- [ ] Implement service mesh features (mutual TLS)
- [ ] Set up Hubble metrics export to InfluxDB
- [ ] Explore Cluster Mesh for multi-cluster networking

## References

### Official Documentation
- [Cilium Installation Using K3s](https://docs.cilium.io/en/stable/installation/k3s/)
- [Cilium Migration Guide](https://docs.cilium.io/en/latest/installation/k8s-install-migration/)
- [Cilium System Requirements](https://docs.cilium.io/en/stable/operations/system_requirements/)
- [Cilium Releases](https://github.com/cilium/cilium/releases)
- [K3s Network Options](https://docs.k3s.io/installation/network-options)
- [K3s Basic Network Options](https://docs.k3s.io/networking/basic-network-options)
- [Tutorial: How to Migrate to Cilium](https://isovalent.com/blog/post/tutorial-migrating-to-cilium-part-1/)

### ARM64/eBPF References
- [Cilium ARM64 Multicast Issue](https://github.com/cilium/cilium/issues/33408) - Kernel 6.0+ required for ARM64 multicast
- [eBPF ARM64 Support](https://github.com/cilium/ebpf/issues/266) - CI testing on ARM64

### Related Avalanche Documentation
- [Network Architecture](../architecture/network/README.md)
- [K3s Sysctl Tuning](../architecture/network/k3s-sysctl-tuning.md)
- [Tailscale Architecture](../architecture/network/tailscale-architecture.md)
- [VPN Egress Architecture](../architecture/network/vpn-egress-architecture.md)

## Appendix: Quick Reference

### Critical Settings Summary

| Setting | Value | Notes |
|---------|-------|-------|
| Cilium Version | 1.16.11 | Latest stable as of Dec 2025 |
| k8sServiceHost | 10.1.0.5 | kube-vip VIP |
| k8sServicePort | 6443 | API server port |
| Pod CIDR | 10.42.0.0/16 | k3s default |
| Service CIDR | 10.43.0.0/16 | k3s default |
| Routing Mode | native | Better performance than tunnel |
| kube-proxy Replacement | false (initially) | Enable after validation |
| Hubble | enabled | Observability |

### NixOS Flags Summary

For k3s servers (controllers):
```
--flannel-backend=none
--disable-network-policy
```

For k3s agents (workers):
- No additional CNI flags needed (agents get CNI config from server)

### Validation Checklist

Post-migration, verify:
- [ ] All nodes show `Ready`
- [ ] All Cilium pods running (9 total - one per node)
- [ ] Cilium Operator running
- [ ] Hubble Relay running
- [ ] Hubble UI accessible
- [ ] Pod-to-pod connectivity (same node)
- [ ] Pod-to-pod connectivity (cross-node)
- [ ] Service DNS resolution
- [ ] NetworkPolicy enforcement
- [ ] Ingress traffic working
- [ ] Longhorn replication working
- [ ] Gluetun VPN tunnels working
- [ ] kube-vip VIP accessible
- [ ] ArgoCD syncing
- [ ] Prometheus collecting Cilium metrics

---

**Created**: 2025-12-27
**Last Updated**: 2025-12-27
**Status**: 🚧 Planning phase - awaiting user approval to proceed
