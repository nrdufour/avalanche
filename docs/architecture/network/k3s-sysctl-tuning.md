# K3s Network Sysctl Tuning

**Status**: Planned
**Date**: 2025-12-25
**Author**: Infrastructure Team

## Overview

This document describes network kernel parameter (sysctl) tuning for the K3s cluster nodes (Orange Pi 5 Plus controllers and Raspberry Pi 4 workers). These optimizations address connection tracking limits, buffer sizing for ARM SBCs, and TCP connection handling for containerized workloads.

## The Container Namespacing Problem

**Critical Understanding**: Network namespaces in Linux containers do **not** inherit sysctl values from the parent namespace. Instead, they use compiled-in kernel defaults.

**Reference**: [Tuning network sysctls in Docker and Kubernetes](https://medium.com/mercedes-benz-techinnovation-blog/tuning-network-sysctls-in-docker-and-kubernetes-766e05da4ff2) - Mercedes-Benz Tech Innovation, July 2020

**Implication**: Setting sysctls in `/etc/sysctl.d` (or NixOS `boot.kernel.sysctl`) affects only:
- Host networking stack
- Kubernetes infrastructure (kube-proxy, CNI plugins, kubelet)
- **Not** the pods themselves (unless explicitly configured per-pod)

This is why we need **two-layer tuning**:
1. **Node-level sysctls**: For Kubernetes infrastructure and host networking
2. **Pod-level sysctls**: For specific high-traffic applications (configured in pod specs)

## Proposed Node-Level Sysctls

These apply to all K3s nodes (controllers and workers) and affect the host networking stack, kube-proxy, and CNI plugins (Flannel VXLAN).

### 1. Connection Tracking (Netfilter Conntrack)

**Problem**: The default connection tracking table size (~65k entries) can be exhausted under moderate load, causing "nf_conntrack: table full, dropping packet" errors and connection failures.

**Workloads Affected**:
- Nginx Ingress Controller (proxying to multiple backend services)
- Gluetun VPN proxy (NAT translation for qbittorrent, IRC bot)
- CloudNative-PG database connections
- Service mesh traffic (pod-to-pod via kube-proxy NAT)

**Configuration**:
```nix
# Increase connection tracking table size
# Default: ~65536 (auto-calculated from available memory)
# New: 262144 (4x increase)
"net.netfilter.nf_conntrack_max" = 262144;

# Reduce TIME_WAIT connection tracking timeout
# Default: 120 seconds
# New: 30 seconds
# Rationale: Faster cleanup of closed connections, more table slots available
"net.netfilter.nf_conntrack_tcp_timeout_time_wait" = 30;
```

**Memory Impact**: ~16 bytes per conntrack entry = 262144 × 16 bytes ≈ 4MB additional memory usage (negligible on 4GB+ RAM systems).

**References**:
- [Netfilter Connection Tracking](https://wiki.nftables.org/wiki-nftables/index.php/Connection_Tracking_System)
- [Kubernetes Services and conntrack](https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies)

---

### 2. Socket Queue Depth

**Problem**: Default listen queue sizes are tuned for traditional servers, not for high-concurrency ingress proxies and API endpoints.

**Workloads Affected**:
- Nginx Ingress (accepting connections from internet)
- Ollama API (LLM inference requests)
- NPU Inference Service (ML model serving)
- Web applications (Miniflux, SearXNG, Wallabag, etc.)

**Configuration**:
```nix
# Increase maximum listen queue depth (max backlog for accept())
# Default: 4096
# New: 32768
# Rationale: Prevent connection drops during traffic bursts
"net.core.somaxconn" = 32768;

# Increase SYN backlog (half-open connections)
# Default: 1024
# New: 8192
# Rationale: Handle SYN floods and connection bursts gracefully
"net.ipv4.tcp_max_syn_backlog" = 8192;
```

**Trade-off**: Higher memory usage for socket buffers (~1-2MB additional), but prevents user-visible connection failures during traffic spikes.

**References**:
- [The Mysterious Container net.core.somaxconn](http://arthurchiao.art/blog/the-mysterious-container-somaxconn/) - Technical deep-dive
- [Linux Networking Documentation - Socket Options](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)

---

### 3. Network Buffers (ARM SBC Optimization)

**Problem**: ARM single-board computers (Orange Pi 5 Plus, Raspberry Pi 4) have conservative default buffer sizes that can bottleneck high-throughput workloads.

**Workloads Affected**:
- Media streaming (qbittorrent downloads, future Plex/Jellyfin)
- Large model transfers (Ollama pulling multi-GB models)
- NPU inference (transferring images/video frames)
- Container image pulls (ArgoCD syncs, pod deployments)

**Configuration**:
```nix
# Increase socket buffer maximum sizes
# Default: 208-212 KB (varies by kernel)
# New: 16 MB
# Rationale: Same fix as eagle host (nixos/hosts/eagle/default.nix:45-50)
#            Prevents "broken pipe" errors on heavy transfers
"net.core.rmem_max" = 16777216;      # Receive buffer max
"net.core.wmem_max" = 16777216;      # Send buffer max

# Increase default buffer sizes
# Default: 208 KB
# New: 256 KB
"net.core.rmem_default" = 262144;
"net.core.wmem_default" = 262144;

# TCP-specific auto-tuning buffers (min, default, max)
# Default: "4096 131072 6291456" (min 4KB, default 128KB, max 6MB)
# New: "4096 87380 16777216" (min 4KB, default 85KB, max 16MB)
# Rationale: Higher max allows TCP to scale buffers for high-BDP links
"net.ipv4.tcp_rmem" = "4096 87380 16777216";
"net.ipv4.tcp_wmem" = "4096 65536 16777216";
```

**Evidence**: eagle host already uses similar buffer tuning (16MB max) to fix Docker buildkit "broken pipe" errors during multi-arch builds (see `nixos/hosts/eagle/default.nix:42-50`).

**References**:
- [TCP Tuning for Linux](https://fasterdata.es.net/network-tuning/linux/)
- eagle host investigation: `docs/plans/forgejo-runner-upgrade-plan.md`

---

### 4. TCP Connection Handling

**Problem**: Services making many short-lived outbound connections (webhooks, API calls, database queries) can exhaust ephemeral ports or wait for TIME_WAIT expiry.

**Workloads Affected**:
- qbittorrent (hundreds of concurrent peer connections)
- IRC bot via Gluetun (persistent IRC + HTTP API calls)
- ArgoCD/Flux (polling Git repositories, Kubernetes API calls)
- Prometheus scraping (metrics collection from all pods)

**Configuration**:
```nix
# Enable TIME_WAIT socket reuse for outbound connections
# Default: 0 (disabled)
# New: 1 (enabled)
# Rationale: Allows fast connection recycling when client initiates connection
# Safe: Only affects outbound connections (client side)
"net.ipv4.tcp_tw_reuse" = 1;

# Expand ephemeral port range for outbound connections
# Default: "32768 60999" (28,232 ports available)
# New: "10000 65535" (55,536 ports available, ~2x increase)
# Rationale: More concurrent outbound connections before port exhaustion
"net.ipv4.ip_local_port_range" = "10000 65535";
```

**Safety Notes**:
- `tcp_tw_reuse` is **safe** (only client-side, uses TCP timestamps for safety)
- `tcp_tw_recycle` is **unsafe** (breaks NAT, removed in kernel 4.12+) - we do NOT use this

**References**:
- [Coping with the TCP TIME-WAIT state on busy Linux servers](https://vincent.bernat.ch/en/blog/2014-tcp-time-wait-state-linux) - Authoritative deep-dive by Vincent Bernat
- [TCP TIME_WAIT and Fast Socket Reuse](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html#tcp-variables)

---

## Pod-Level Sysctls (Future Work)

Per the Mercedes-Benz article, certain sysctls are **namespaced** and must be set per-pod to take effect inside containers.

### Safe Sysctls (Allowed by Default)

These can be set in pod specs without cluster configuration changes:
- `net.ipv4.ip_local_port_range` - Per-pod ephemeral ports
- `net.ipv4.tcp_syncookies` - SYN flood protection (enabled by default)
- `kernel.shm_rmid_forced` - Shared memory cleanup

### Unsafe Sysctls (Require Kubelet Configuration)

For high-traffic pods (Nginx Ingress, Ollama), we may want to set:
- `net.core.somaxconn` - Per-pod listen queue depth
- `net.ipv4.tcp_tw_reuse` - Per-pod TIME_WAIT reuse

**To Enable**: Add to K3s kubelet args:
```nix
services.k3s.extraFlags = [
  "--kubelet-arg=allowed-unsafe-sysctls=net.core.somaxconn,net.ipv4.tcp_tw_reuse"
];
```

**Recommendation**: Start with node-level tuning only. Add pod-level sysctls later if monitoring shows specific pods are bottlenecked.

---

## Implementation Plan

### Phase 1: Node-Level Tuning (Minimal Risk)

Add to `nixos/profiles/role-k3s-controller.nix` and `role-k3s-worker.nix`:

**Minimum (Recommended)**:
```nix
boot.kernel.sysctl = {
  # Connection tracking (prevent table exhaustion)
  "net.netfilter.nf_conntrack_max" = 262144;
  "net.netfilter.nf_conntrack_tcp_timeout_time_wait" = 30;

  # Network buffers (ARM SBC optimization, proven on eagle host)
  "net.core.rmem_max" = 16777216;
  "net.core.wmem_max" = 16777216;
  "net.core.rmem_default" = 262144;
  "net.core.wmem_default" = 262144;
  "net.ipv4.tcp_rmem" = "4096 87380 16777216";
  "net.ipv4.tcp_wmem" = "4096 65536 16777216";
};
```

**Optional (If Experiencing Connection Issues)**:
```nix
  # Socket queue depth (high-traffic ingress)
  "net.core.somaxconn" = 32768;
  "net.ipv4.tcp_max_syn_backlog" = 8192;

  # TCP connection handling (many short-lived connections)
  "net.ipv4.tcp_tw_reuse" = 1;
  "net.ipv4.ip_local_port_range" = "10000 65535";
```

**Deployment**:
1. Apply to one worker node first (`just nix-deploy raccoon00`)
2. Monitor for 24-48 hours (see Monitoring section below)
3. If stable, deploy to all K3s nodes (`just nix-deploy opi01 opi02 opi03 raccoon01 raccoon02 raccoon03 raccoon04 raccoon05`)

### Phase 2: Pod-Level Tuning (If Needed)

Only proceed if monitoring shows specific pods hitting limits:
1. Enable unsafe sysctls in kubelet configuration
2. Add pod-level sysctls to high-traffic applications (Nginx Ingress, Ollama)
3. Monitor impact on performance and stability

---

## Monitoring

### Before/After Metrics

**Connection Tracking**:
```bash
# Current conntrack usage
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# Check for dropped connections (should be 0)
dmesg | grep "nf_conntrack: table full"
```

**Socket Buffer Usage**:
```bash
# Socket memory usage
cat /proc/net/sockstat

# TCP memory pressure (should remain 0)
cat /proc/net/sockstat | grep "TCP: inuse"
```

**Ephemeral Port Usage**:
```bash
# Active connections by state
ss -tan | awk '{print $1}' | sort | uniq -c

# TIME_WAIT count (should decrease with tcp_tw_reuse=1)
ss -tan | grep TIME-WAIT | wc -l
```

### Prometheus Queries (if node-exporter is deployed)

```promql
# Conntrack usage percentage
node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100

# Socket buffer memory
node_sockstat_TCP_mem_bytes

# TCP connection states
node_netstat_Tcp_CurrEstab
```

### Expected Improvements

- **Conntrack**: Usage should stay well below 262k limit (currently may spike near 65k)
- **Socket buffers**: Fewer "broken pipe" errors in container logs
- **TIME_WAIT**: Faster port recycling (lower TIME_WAIT count)
- **Connection drops**: Zero "connection refused" errors during traffic bursts

---

## Rollback Plan

If issues occur after deployment:

1. **Immediate rollback** (single node):
   ```bash
   ssh <node>.internal
   sudo sysctl -w net.netfilter.nf_conntrack_max=65536  # Reset to default
   # ... reset other values ...
   sudo systemctl restart k3s
   ```

2. **Permanent rollback** (NixOS):
   - Revert commit changing `role-k3s-*.nix`
   - Redeploy: `just nix-deploy <node>`

3. **Known issues to watch for**:
   - Memory pressure on 4GB Raspberry Pi workers (unlikely, total overhead ~10MB)
   - Incompatibility with specific CNI plugins (Flannel VXLAN is well-tested)
   - Unexpected behavior with kube-proxy iptables rules (rare)

---

## References

1. **Primary Source**: [Tuning network sysctls in Docker and Kubernetes](https://medium.com/mercedes-benz-techinnovation-blog/tuning-network-sysctls-in-docker-and-kubernetes-766e05da4ff2) - Mercedes-Benz Tech Innovation, July 2020

2. **TCP TIME_WAIT Deep Dive**: [Coping with the TCP TIME-WAIT state on busy Linux servers](https://vincent.bernat.ch/en/blog/2014-tcp-time-wait-state-linux) - Vincent Bernat

3. **Kubernetes Documentation**: [Using sysctls in a Kubernetes Cluster](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/)

4. **Linux Kernel Documentation**: [IP Sysctl](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)

5. **Connection Tracking**: [Netfilter Connection Tracking System](https://wiki.nftables.org/wiki-nftables/index.php/Connection_Tracking_System)

6. **TCP Buffer Tuning**: [TCP Tuning for Linux](https://fasterdata.es.net/network-tuning/linux/) - ESnet

7. **Container Networking**: [The Mysterious Container net.core.somaxconn](http://arthurchiao.art/blog/the-mysterious-container-somaxconn/) - Arthur Chiao

8. **Internal Evidence**: `nixos/hosts/eagle/default.nix:42-50` - Socket buffer tuning for Docker buildkit

---

## Revision History

- **2025-12-25**: Initial documentation (planning phase)
