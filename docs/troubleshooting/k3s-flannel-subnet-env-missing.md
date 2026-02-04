# k3s Flannel subnet.env Not Created After Reboot on Server Nodes

**Status**: RESOLVED (2026-02-04)

## Summary

After a reboot, k3s server nodes with embedded etcd may fail to initialize the flannel networking backend. The embedded flannel silently fails to write `/run/flannel/subnet.env`, causing all pod sandbox creation to fail.

## Solution

**Root cause**: The `--disable-cloud-controller` flag was set, which disables the embedded Cloud Controller Manager (CCM). Without the CCM, the `node.cloudprovider.kubernetes.io/uninitialized` taint is never cleared from nodes. Flannel waits for this taint to be removed before initializing, causing the indefinite delay.

**Fix**: Remove `--disable-cloud-controller` from the k3s server flags.

The k3s embedded CCM performs three functions:
1. **Clears the node initialization taint** - This is critical for flannel to start
2. **Hosts the ServiceLB (Klipper) LoadBalancer controller** - Can be separately disabled with `--disable=servicelb` if not needed
3. **Sets node address fields** - Based on `--node-ip`, `--node-external-ip`, etc.

The fix was applied in commit removing the flag from `nixos/modules/nixos/services/k3s/default.nix`.

## Environment

- **k3s version**: 1.34.3+k3s1
- **OS**: NixOS 25.11
- **Architecture**: aarch64 (Orange Pi 5 Plus with RK3588)
- **Kernel**: Linux 6.18.8 (issue NOT observed with 6.18.7 and earlier)
- **Cluster configuration**: 3 server nodes with embedded etcd (HA), 6 agent nodes (Raspberry Pi 4)
- **Flannel backend**: vxlan (default)
- **Date observed**: 2026-02-02

## Version History

The affected node (opi01) has been rebooting regularly through kernel updates:

| Kernel | Reboot Date | Flannel Issue |
|--------|-------------|---------------|
| 6.18.7 | 2026-01-30 | No |
| 6.18.6 | 2026-01-20 | No |
| 6.18.5 | 2026-01-14 | No |
| 6.18.4 | 2026-01-13 | No |
| 6.18.3 | 2026-01-05 | No |
| 6.18.2 | 2025-12-27 | No |
| 6.18.8 | 2026-02-02 | **YES** |

The k3s version (1.34.3+k3s1) did NOT change between the working (6.18.7) and broken (6.18.8) configurations. This suggests the kernel update may have introduced a timing change that exposes a latent race condition in k3s's flannel initialization.

## Symptoms

After rebooting a k3s server node, all pods scheduled on that node fail to start with:

```
Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network
for sandbox "...": plugin type="flannel" failed (add): loadFlannelSubnetEnv failed:
open /run/flannel/subnet.env: no such file or directory
```

The file `/run/flannel/subnet.env` does not exist and is never created.

## Impact

1. No pods can start on the affected node
2. If kured (Kubernetes Reboot Daemon) cordoned the node before rebooting, the kured pod cannot start to uncordon it
3. The kured lock remains held on the DaemonSet annotation, blocking coordinated reboots on other nodes
4. The node remains in `Ready,SchedulingDisabled` state indefinitely

## Cascade Effect on Longhorn and Other Nodes

The flannel failure on one node can cause **cascade failures on other healthy nodes** due to pods being assigned invalid IP addresses during the partial outage.

### How the Cascade Happens

1. When flannel is broken on server nodes (e.g., opi01 and opi03), but working on another (e.g., opi02), the cluster continues operating in a degraded state

2. During this period, some pods on the "healthy" node may be assigned IPs from an invalid/fallback subnet (e.g., `10.42.255.x` instead of `10.42.1.x`)

3. These pods with invalid IPs cannot communicate with the Kubernetes API (`10.43.0.1:443`) or other cluster services:
   ```
   dial tcp 10.43.0.1:443: connect: no route to host
   ```

4. If Longhorn manager pods are affected, Longhorn marks the node as "not ready":
   ```
   kubectl get nodes.longhorn.io -n longhorn-system
   NAME    READY   ALLOWSCHEDULING   SCHEDULABLE
   opi02   False   true              True          # <-- False due to broken networking
   ```

5. With Longhorn node not ready:
   - Volume attachments fail with "node is not ready"
   - CSI provisioner enters CrashLoopBackOff (can't connect to CSI socket)
   - All pods requiring Longhorn PVCs get stuck in `ContainerCreating`

### Symptoms of Cascade Failure

- Pods on seemingly healthy nodes have IPs in unexpected subnets (e.g., `10.42.255.x`)
- Longhorn node shows `READY=False` even though Kubernetes node shows `Ready`
- Volume attachment errors: "unable to attach volume X to nodeY: node nodeY is not ready"
- Multiple pods stuck in `ContainerCreating` waiting for volumes

### Identifying Affected Pods

```bash
# Find pods with invalid IPs (10.42.255.x is a common fallback)
kubectl get pods -A -o wide | grep "10.42.255"
```

### Recovery Steps

1. **First**, fix the root cause (create `/run/flannel/subnet.env` on affected nodes)

2. **Then**, delete all pods with invalid IPs to force them to restart with correct networking:
   ```bash
   # Identify pods with broken IPs
   kubectl get pods -A -o wide | grep "10.42.255"

   # Delete them (they'll be recreated by their controllers)
   kubectl delete pod -n <namespace> <pod-name>
   ```

3. **Finally**, delete any pods stuck in `ContainerCreating` to trigger fresh volume attachment:
   ```bash
   kubectl get pods -A | grep ContainerCreating
   kubectl delete pod -n <namespace> <pod-name>
   ```

### Prevention

Do not use `--disable-cloud-controller` unless you have an external cloud controller manager deployed that will clear the node initialization taint. The embedded CCM is required for flannel to initialize properly on bare-metal/on-premise clusters.

## Root Cause Analysis

### Expected Behavior

On a working k3s startup, the following log messages appear:

```
level=info msg="Starting flannel with backend vxlan"
level=info msg="Running flannel backend."
```

Flannel then writes `/run/flannel/subnet.env` with contents like:

```
FLANNEL_NETWORK=10.42.0.0/16
FLANNEL_SUBNET=10.42.1.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
```

### Observed Behavior on Affected Nodes

On server nodes after reboot, the flannel startup messages **never appear**. The startup sequence shows:

```
level=info msg="Starting k3s 1.34.3+k3s1 (48ffa7b6)"
level=info msg="Managed etcd cluster bootstrap already complete and initialized"
level=info msg="Starting temporary etcd to reconcile with datastore"
[... etcd startup with force-new-cluster:true ...]
[... etcd defragmentation ...]
level=info msg="Starting etcd for existing cluster member"
[... kube-apiserver, kube-proxy startup ...]
"Updating Pod CIDR" originalPodCIDR="" newPodCIDR="10.42.0.0/24"
[... immediate pod sandbox failures ...]
```

The kubelet receives its Pod CIDR assignment from the controller-manager, but flannel never initializes to write the subnet.env file.

### Key Observation

The issue appears specific to the **server startup path** when the node goes through etcd reconciliation:

1. **Server nodes (affected)**: Go through "Starting temporary etcd to reconcile with datastore" phase with `force-new-cluster: true`
2. **Agent nodes (not affected)**: Simply connect to the server without the etcd reconciliation complexity

In our cluster of 3 server nodes and 6 agent nodes, only the server nodes exhibited this issue after reboot. Agent nodes (Raspberry Pi 4) rebooted without any flannel problems.

### Timing

The etcd reconciliation phase takes approximately 15-20 seconds. During this time, various components start in parallel. It appears that flannel initialization is either:
- Skipped due to a race condition
- Started but fails silently without logging
- Waiting on a condition that is never satisfied

### Actual Root Cause (Discovered 2026-02-04)

The `--disable-cloud-controller` flag was the culprit. When this flag is set:

1. The embedded Cloud Controller Manager (CCM) is disabled
2. No component clears the `node.cloudprovider.kubernetes.io/uninitialized` taint from nodes
3. Flannel waits for this taint to be cleared before it initializes
4. The taint is never cleared, so flannel never starts

This explains why:
- **Server nodes were affected**: They have the taint applied at startup
- **Agent nodes were not affected**: They don't go through the same taint/CCM logic
- **The kernel timing change exposed it**: Faster kernel boot in 6.18.8 may have changed the race timing, but the underlying issue was always present

See [k3s-io/k3s#11619](https://github.com/k3s-io/k3s/issues/11619) for the upstream confirmation that flannel cannot start until the uninitialized taint is cleared.

## Steps to Reproduce

1. Set up a k3s HA cluster with 3+ server nodes using embedded etcd
2. **Configure k3s with `--disable-cloud-controller`** (this is the key factor)
3. Install kured for coordinated reboots
4. Trigger a reboot on a server node (via kured or manually)
5. After the node comes back up, observe that pods fail to schedule with the flannel subnet.env error

## Workaround (Deprecated)

> **Note**: This workaround is no longer needed. The proper fix is to remove `--disable-cloud-controller` from k3s server flags. See the Solution section above.

Create `/run/flannel/subnet.env` manually or via a systemd unit that runs before k3s:

```bash
mkdir -p /run/flannel
cat > /run/flannel/subnet.env <<EOF
FLANNEL_NETWORK=10.42.0.0/16
FLANNEL_SUBNET=10.42.X.1/24  # X = node's assigned subnet
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
EOF
```

The subnet value can be derived from the node's `.spec.podCIDR` in Kubernetes, or from the `flannel.alpha.coreos.com/backend-data` annotation on the node.

## Related Issues

- https://github.com/k3s-io/k3s/issues/8179 - Similar symptom on worker nodes
- https://github.com/k3s-io/k3s/issues/11619 - Related to `--disable-cloud-controller` and uninitialized taint
- https://github.com/k3s-io/k3s/issues/2599 - Flannel fails after reboot (different root cause)

## Additional Information

### k3s Server Flags (At Time of Issue)

```
--disable=local-storage
--disable=traefik
--disable=metrics-server
--disable-cloud-controller   # <-- THIS WAS THE PROBLEM
--embedded-registry
--etcd-expose-metrics
```

### k3s Server Flags (After Fix)

```
--disable=local-storage
--disable=traefik
--disable=metrics-server
--embedded-registry
--etcd-expose-metrics
```

### Node Annotations (flannel-related)

The affected nodes have correct flannel annotations, indicating the control plane knows about the flannel configuration:

```json
{
  "flannel.alpha.coreos.com/backend-data": "{\"VNI\":1,\"VtepMAC\":\"5a:43:48:b2:31:9f\"}",
  "flannel.alpha.coreos.com/backend-type": "vxlan",
  "flannel.alpha.coreos.com/kube-subnet-manager": "true",
  "flannel.alpha.coreos.com/public-ip": "10.1.0.20"
}
```

### CNI Configuration

The CNI configuration at `/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist` is identical on working and non-working nodes:

```json
{
  "name": "cbr0",
  "cniVersion": "1.0.0",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "forceAddress": true,
        "isDefaultGateway": true
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}},
    {"type": "bandwidth", "capabilities": {"bandwidth": true}}
  ]
}
```
