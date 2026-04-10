# Longhorn to LINSTOR (Piraeus) Migration Plan (Issue #131)

**Status**: 🚧 In Progress (Phase 4 — Batch 4 complete, Batch 5 next)
**Created**: 2026-04-08
**Last Updated**: 2026-04-09
**Storage approach**: LVM_THIN via 300GB loopback file on NVMe root partition

## Overview

Migrate persistent storage from Longhorn 1.11.1 to LINSTOR (Piraeus Operator v2) on the K3s cluster. Longhorn replicates data in userspace, consuming excessive CPU on ARM SBCs — during a 2026-04-08 incident, an instance-manager hit 1031m CPU on raccoon00 during VolSync snapshot clone rebuilds. LINSTOR uses DRBD for kernel-level replication, eliminating this overhead.

**Migration strategy**: Deploy LINSTOR alongside Longhorn, then restore each app from existing VolSync restic backups (S3/Garage) into new LINSTOR PVCs. No live data migration needed.

## NixOS Package Availability (verified 2026-04-08)

| Package | Nixpkgs Attribute | Version | Notes |
|---------|------------------|---------|-------|
| DRBD kernel module | `linuxPackages.drbd` | 9.3.1 (overlay) | 9.2.15 broken on 6.18; overlay in `nixos/overlays/default.nix`. Remove once nixpkgs#504903 merges |
| DRBD userspace | `drbd` | 9.33.0 | — |
| LVM2 | `lvm2` | 2.03.35 | — |
| thin-provisioning-tools | `thin-provisioning-tools` | 1.3.0 | — |

## Progress

- [x] **Phase 1: NixOS host prep** — DRBD 9.3.1 + LVM tools + dm-thin-pool/dm-snapshot modules
  - `linstorSupport` option in `nixos/modules/nixos/services/k3s/default.nix`
  - DRBD 9.3.1 overlay for kernel 6.18 in `nixos/overlays/default.nix`
  - Loopback-backed LVM thin pool (300GB per node) via systemd service
  - `/usr/src` directory creation for Piraeus satellite hostPath mount
  - `usermode_helper=disabled` via `boot.extraModprobeConfig`
  - opi01-03: deployed, rebooted, DRBD 9.3.1 loaded, pools working
  - raccoon00-05: deployed, rebooted, DRBD 9.2.15 loaded, satellites running as diskless clients
- [x] **Phase 2: Piraeus Operator deployment** — v2.10.5
  - ArgoCD Application at `kubernetes/base/infra/piraeus/`
  - LinstorCluster CR with NixOS PATH patch + drbd9-none init container
  - LinstorSatelliteConfiguration: LVM_THIN pool on opi01-03 only
  - StorageClass `linstor` (2 replicas, diskless remote access)
  - VolumeSnapshotClass `linstor-snapshot`
  - End-to-end test passed: PVC provisioning + LVM thin snapshots verified
  - Prometheus ServiceMonitors for LINSTOR controller + Piraeus operator
  - Grafana dashboard "LINSTOR Storage" (node state, pool capacity/usage, resource/volume state, errors)
- [x] **Phase 3: VolSync template updates** — parameterize snapshot class + cleanupTempPVC
- [ ] **Phase 4: Per-app migration** — restore from restic into LINSTOR PVCs
- [ ] **Phase 5: Longhorn decommission** — after all apps stable for 1 week

## Blockers

None. All nodes deployed, rebooted, and online.

## Lessons Learned (so far)

- **DRBD 9.2.x is broken on kernel 6.16+** in nixpkgs. Override to 9.3.1 via flake overlay. Track nixpkgs#504903 to remove the overlay.
- **FILE_THIN does NOT support snapshots** despite `CanSnapshots: True` in pool listing. Must use LVM_THIN for VolSync compatibility.
- **NixOS needs extra kernel modules** for LVM thin: `dm-thin-pool` and `dm-snapshot` (not loaded by default).
- **`boot.extraModulePackages` DRBD 9 requires reboot** — `nixos-rebuild switch` doesn't reload kernel modules. The in-tree DRBD 8 stays loaded until reboot.
- **`usermode_helper=disabled`** must be set via `extraModprobeConfig` — Piraeus satellite init container rejects DRBD loaded with default `usermode_helper=/sbin/drbdadm`.
- **Piraeus satellite needs `/usr/src`** as a hostPath mount even when using `drbd9-none` (no-op). NixOS doesn't have `/usr/src` — create it via activation script.
- **LinstorSatelliteConfiguration can't change pool type in-place** — must delete and recreate the resource to switch from FILE_THIN to LVM_THIN.
- **Piraeus OCI Helm chart path** is `oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus` (not `helm-charts/piraeus-operator`). Use `path: .` in ArgoCD multi-source (same pattern as snapshot-controller).
- **`installCRDs: true`** must be set in Helm values — defaults to false.
- **LINSTOR metric label is `storage_pool`** (with underscore), not `storagepool`. Filter pool metrics with `{storage_pool="ssd-thin"}` to exclude diskless pools.
- **ArgoCD CMP cache survives Application env var changes** — updating plugin env vars in the Application object does NOT invalidate the CMP manifest cache. You must sync `applications` parent first (to update the Application object), THEN `--hard-refresh` the child app to regenerate CMP output.
- **dataSourceRef removal patch blocks migration restores** — most apps have a kustomize patch removing `dataSourceRef` from the PVC (to prevent re-restore on sync). This must be temporarily removed during migration so the new PVC clones from the ReplicationDestination snapshot. Re-add after PVC is bound.
- **PVC created without dataSourceRef gets empty Longhorn volume** — if ArgoCD syncs before the Application env vars are updated (stale CMP cache), it creates a bare PVC on the old storage class. Must delete and recreate after fixing the cache.
- **Disable auto-sync on `cluster` and `applications` for the entire batch** — re-enabling mid-migration causes race conditions where ArgoCD scales deployments back up or syncs stale manifests.
- **Add `ignoreDifferences` for PVC dataSourceRef/dataSource** — after migration, the live PVC has `dataSourceRef` (immutable) but the rendered manifest doesn't (patch removes it). Without `ignoreDifferences` + `RespectIgnoreDifferences=true`, ArgoCD will show perpetual OutOfSync.
- **Pause after push before syncing** — ArgoCD needs time to settle. Immediately syncing after push can hit "another operation is already in progress" errors.
- **Changing `autoPlace` in StorageClass only affects new volumes** — existing volumes need `linstor resource create <node> <resource> --storage-pool ssd-thin` to add replicas. DRBD syncs data automatically.
- **Force-deleting VolSync mover pods leaves stale restic repo locks** — when a mover pod is killed mid-backup, its restic lock persists in S3. Subsequent backups complete the data phase but fail on `forget` (prune) due to the stale lock. Fix with `restic unlock --remove-all` via a one-shot pod using the app's volsync secret and CA cert.
- **Longhorn snapshot clone "not ready for workloads" is often transient** — the cloned volume needs time to rebuild replicas. Don't delete too quickly; give it 2-3 minutes. For large volumes (10Gi+) on ARM nodes, this can take longer but does eventually complete.

## Current Storage Topology

| Node | Role | Hardware | Kernel | Storage | Longhorn Data |
|------|------|----------|--------|---------|---------------|
| opi01 | controller | OPi5+ SSD | 6.18 | SSD (fstrim) | /var/lib/rancher/longhorn |
| opi02 | controller | OPi5+ SSD | 6.18 | SSD (fstrim) | /var/lib/rancher/longhorn |
| opi03 | controller | OPi5+ SSD | 6.18 | SSD (fstrim) | /var/lib/rancher/longhorn |
| raccoon00 | worker | RPi4 SD | 6.12 | SD card only | /var/lib/rancher/longhorn |
| raccoon01 | worker | RPi4 SD | 6.12 | SD card only | /var/lib/rancher/longhorn |
| raccoon02 | worker | RPi4 SD | 6.12 | SD card only | /var/lib/rancher/longhorn |
| raccoon03 | worker | RPi4 USB | 6.12 | USB SSD at /var/lib/rancher | /var/lib/rancher/longhorn |
| raccoon04 | worker | RPi4 USB | 6.12 | USB SSD at /var/lib/rancher | /var/lib/rancher/longhorn |
| raccoon05 | worker | RPi4 USB | 6.12 | USB SSD at /var/lib/rancher | /var/lib/rancher/longhorn |

**Target**: opi01-03 as LINSTOR storage nodes (SSD, more CPU), raccoons as diskless DRBD clients.

**Important**: Workloads do NOT need to run on opi nodes. DRBD's diskless client mode allows pods on any raccoon to mount LINSTOR volumes over the network via the kernel DRBD module. Data replicas live on opi nodes, but pods are scheduled anywhere. This is fundamentally different from Longhorn, which runs heavy userspace instance-managers on every node with a replica. Current scheduling (most stateful pods on raccoons) will work unchanged.

## Apps to Migrate

### VolSync v2 apps (13 — restore from S3 backup)

| App | Namespace | PVC Size | Schedule | Priority |
|-----|-----------|----------|----------|----------|
| kanboard | self-hosted | — | 51 */6 | Batch 1 (low risk) |
| ntfy | self-hosted | — | 20 * | Batch 1 |
| homebox | self-hosted | — | 48 */6 | Batch 1 |
| thelounge | irc | — | 39 */6 | Batch 1 |
| esphome | home-automation | — | 30 */6 | Batch 2 |
| mqtt | home-automation | — | 10 * | Batch 2 |
| zwave | home-automation | 1Gi | 36 */6 | Batch 2 |
| grafana | home-automation | 1Gi | 33 */6 | Batch 2 |
| home-assistant | home-automation | 1Gi | 0 * | Batch 3 (critical) |
| influxdb2 | home-automation | 10Gi | 54 */6 | Batch 3 (largest) |
| seerr | media | — | 45 */6 | Batch 4 |
| archivebox | media | — | 42 */6 | Batch 4 |
| matrix | self-hosted | — | 15 * | Batch 5 |

### Custom VolSync (1 — manual YAML changes)

| App | Namespace | Notes |
|-----|-----------|-------|
| immich-cache | media | Custom volsync manifests, not using volsync-v2 component |

### Standalone PVC apps (no VolSync — fresh start or manual copy)

| App | Namespace | Data | Migration |
|-----|-----------|------|-----------|
| sonarr, prowlarr, radarr, qbittorrent, nzbget, ytptube | media | Regenerable (indexes, cache) | Fresh start |
| searxng | self-hosted | Regenerable | Fresh start, rename PVC |
| marmithon | irc | Bot state | Manual copy, rename PVC |
| frigate | home-automation | Config + recordings | Manual copy |
| actual | self-hosted | Budget data | Manual copy, rename PVC |
| minecraft | games | World data | Manual copy |
| influxdb2-backup | home-automation | Backup scratch | Fresh start |
| immich-ml-cache | media | ML model cache | Fresh start |

### PVC renames needed

Three apps have Longhorn-specific PVC names that should be cleaned up:
- `marmithon-longhorn-pvc` → `marmithon` (update `irc/marmithon/deployment.yaml`)
- `actual-longhorn-pvc` → `actual` (update `self-hosted/actual/deployment.yaml`)
- `searxng-longhorn-pvc` → `searxng` (update `self-hosted/searxng/deployment.yaml`)

---

## Phase 1: NixOS Host Preparation

### 1.1 Add `linstorSupport` to K3s module

**File**: `nixos/modules/nixos/services/k3s/default.nix`

Add alongside existing `longhornSupport`:

```nix
linstorSupport = mkOption {
  description = "Enable DRBD kernel module and LVM thin-provisioning tools for LINSTOR";
  default = false;
  type = types.bool;
};
```

Config block:

```nix
boot.kernelModules = mkIf cfg.linstorSupport [ "drbd" "drbd_transport_tcp" ];
boot.extraModulePackages = mkIf cfg.linstorSupport [
  config.boot.kernelPackages.drbd
];
environment.systemPackages = optionals cfg.linstorSupport [
  pkgs.drbd
  pkgs.lvm2
  pkgs.thin-provisioning-tools
];
```

### 1.2 Enable on profiles

**Files**: `nixos/profiles/role-k3s-controller.nix`, `nixos/profiles/role-k3s-worker.nix`

```nix
mySystem.services.k3s.linstorSupport = true;
```

Workers need the DRBD kernel module to mount DRBD-backed volumes as diskless clients. LVM/thin-provisioning-tools aren't strictly needed on workers but keeping the config uniform is simpler.

### 1.3 Deploy and verify

```bash
# Deploy controllers first, then workers
just nix deploy opi01 && just nix deploy opi02 && just nix deploy opi03
just nix deploy raccoon00  # ... through raccoon05

# Verify on each node
ssh <host>.internal lsmod | grep drbd
ssh <host>.internal drbdadm --version
```

### 1.4 Storage pool strategy: FILE_THIN on NVMe

All 3 opi nodes have a 2TB NVMe with 1.3-1.6TB free on the root ext4 partition. No spare partition or disk is available without repartitioning. The eMMC (250GB) exists but is not suitable as a starting point.

**Approach**: Use LINSTOR's FILE_THIN storage pool, which creates a file-backed thin pool on an existing filesystem. LINSTOR manages the loopback device natively — no manual LVM setup required.

```
opi01: nvme0n1p2 (2.0TB, 1.6TB free) → FILE_THIN at /var/lib/linstor-pools/
opi02: nvme0n1p2 (1.9TB, 1.6TB free) → FILE_THIN at /var/lib/linstor-pools/
opi03: nvme0n1p2 (1.9TB, 1.3TB free) → FILE_THIN at /var/lib/linstor-pools/
```

No host-side preparation needed — LINSTOR creates the pool directory and backing file automatically via the LinstorSatelliteConfiguration CR.

**Future improvement**: If a dedicated SSD or partition becomes available, migrate to a real LVM thin pool for better performance. LINSTOR supports mixing pool types per node.

---

## Phase 2: Piraeus Operator Deployment

### 2.1 Directory structure

```
kubernetes/base/infra/piraeus/
├── piraeus-app.yaml              # ArgoCD Application (Helm)
├── piraeus/
│   └── helm-values.yaml          # Helm overrides
└── resources/
    ├── kustomization.yaml
    ├── linstor-cluster.yaml      # LinstorCluster CR
    ├── linstor-satellite.yaml    # Storage pool config (opi only)
    ├── storage-class.yaml
    └── snapshot-class.yaml
```

### 2.2 ArgoCD Application

**File**: `kubernetes/base/infra/piraeus/piraeus-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: piraeus
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://forge.internal/nemo/avalanche.git
      targetRevision: HEAD
      path: kubernetes/base/infra/piraeus/resources
      ref: values
    - chart: piraeus-operator
      repoURL: oci://ghcr.io/piraeusdatastore/helm-charts
      targetRevision: 2.7.1  # verify latest
      helm:
        releaseName: piraeus-operator
        valueFiles:
          - $values/kubernetes/base/infra/piraeus/piraeus/helm-values.yaml
  destination:
    namespace: piraeus-system
    name: 'in-cluster'
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 2.3 LinstorCluster CR

**File**: `kubernetes/base/infra/piraeus/resources/linstor-cluster.yaml`

```yaml
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstorcluster
spec:
  patches:
    - target:
        kind: Pod
      patch: |
        apiVersion: v1
        kind: Pod
        metadata:
          name: satellite
        spec:
          containers:
            - name: linstor-satellite
              env:
                - name: PATH
                  value: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin
```

NixOS PATH patch — same issue as Longhorn (currently solved by Kyverno ClusterPolicy), but Piraeus supports inline patches natively.

### 2.4 Satellite configuration (storage on controllers only)

**File**: `kubernetes/base/infra/piraeus/resources/linstor-satellite.yaml`

```yaml
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: controllers-storage
spec:
  nodeSelector:
    node-role.kubernetes.io/control-plane: "true"
  storagePools:
    - name: ssd-thin
      fileThinPool:
        directory: /var/lib/linstor-pools
```

Uses FILE_THIN — LINSTOR creates and manages the backing file and loopback device automatically in the specified directory (on the NVMe root filesystem).

Workers get no storage pool config — they act as diskless DRBD clients.

### 2.5 StorageClass

**File**: `kubernetes/base/infra/piraeus/resources/storage-class.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: linstor
  # Do NOT set as default yet — Longhorn is still default during migration
provisioner: linstor.csi.linbit.com
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  autoPlace: "3"                    # 3 replicas across 3 storage nodes (full redundancy)
  storagePool: ssd-thin
  allowRemoteVolumeAccess: "true"   # Diskless attachment on workers
  csi.storage.k8s.io/fstype: ext4
```

Design: 3 replicas across 3 storage nodes — every volume has a copy on all opi nodes. With only 3 storage nodes, this is the right call: storage cost is negligible and it survives 2 simultaneous node failures.

### 2.6 VolumeSnapshotClass

**File**: `kubernetes/base/infra/piraeus/resources/snapshot-class.yaml`

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: linstor-snapshot
driver: linstor.csi.linbit.com
deletionPolicy: Delete
```

### 2.7 Register in infra kustomization

**File**: `kubernetes/base/infra/kustomization.yaml` — add `piraeus/piraeus-app.yaml`

### 2.8 Verification

```bash
kubectl -n piraeus-system get pods
kubectl -n piraeus-system exec deploy/linstor-controller -- linstor node list
kubectl -n piraeus-system exec deploy/linstor-controller -- linstor storage-pool list
# Expect ssd-thin on opi01, opi02, opi03 only
```

### 2.9 End-to-end test

```bash
# Create test PVC + pod + snapshot, verify everything works, then clean up
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: linstor-test
spec:
  storageClassName: linstor
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: linstor-test-pod
spec:
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c", "echo hello > /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: linstor-test
EOF

kubectl wait --for=condition=Ready pod/linstor-test-pod --timeout=120s

# Test snapshot
kubectl apply -f - <<'EOF'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: linstor-test-snap
spec:
  volumeSnapshotClassName: linstor-snapshot
  source:
    persistentVolumeClaimName: linstor-test
EOF

kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/linstor-test-snap --timeout=60s

# Clean up
kubectl delete pod linstor-test-pod
kubectl delete volumesnapshot linstor-test-snap
kubectl delete pvc linstor-test
```

---

## Phase 3: VolSync Template Updates

### 3.1 Parameterize volumeSnapshotClassName

**Files**:
- `kubernetes/base/components/volsync-v2/replication-source.yaml` — change `volumeSnapshotClassName: longhorn-snapshot-vsc` to `"${ARGOCD_ENV_VOLSYNC_SNAPSHOT_CLASS}"`
- `kubernetes/base/components/volsync-v2/replication-destination.yaml` — same change + parameterize `cleanupTempPVC: ${ARGOCD_ENV_VOLSYNC_CLEANUP_TEMP_PVC}`

Add variable docs:
```
#   ARGOCD_ENV_VOLSYNC_SNAPSHOT_CLASS - Volume snapshot class (REQUIRED)
#   ARGOCD_ENV_VOLSYNC_CLEANUP_TEMP_PVC - Clean up temp PVC after sync (REQUIRED, "true" or "false")
```

Update the `cleanupTempPVC` comment:
```yaml
# Longhorn requires false (deletes volume with temp PVC). LINSTOR supports true.
```

### 3.2 Add new env vars to ALL 13 app manifests (same commit!)

**Critical**: envsubst replaces unset vars with empty strings. The template changes and variable additions MUST be in a single atomic commit.

Add to each `-app.yaml`:
```yaml
        - name: VOLSYNC_SNAPSHOT_CLASS
          value: longhorn-snapshot-vsc
        - name: VOLSYNC_CLEANUP_TEMP_PVC
          value: "false"
```

Apps to update:
1. `home-automation/esphome-app.yaml`
2. `home-automation/grafana-app.yaml`
3. `home-automation/home-assistant-app.yaml`
4. `home-automation/influxdb2-app.yaml`
5. `home-automation/mqtt-app.yaml`
6. `home-automation/zwave-app.yaml`
7. `irc/thelounge-app.yaml`
8. `media/archivebox-app.yaml`
9. `media/seerr-app.yaml`
10. `self-hosted/homebox-app.yaml`
11. `self-hosted/kanboard-app.yaml`
12. `self-hosted/matrix-app.yaml`
13. `self-hosted/ntfy-app.yaml`

### 3.3 Update volsync-v2 README

Add `VOLSYNC_SNAPSHOT_CLASS` and `VOLSYNC_CLEANUP_TEMP_PVC` to the variables table.

### 3.4 Verification

```bash
# After single-commit deploy, verify all ReplicationSources still have correct snapshot class
kubectl get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.restic.volumeSnapshotClassName}{"\n"}{end}'
# All should show longhorn-snapshot-vsc

# Wait for next scheduled backup to succeed for at least one app
```

---

## Phase 4: Per-App Migration

### Prerequisites

Disable auto-sync on `cluster` and `applications` ArgoCD apps before starting a migration batch. Keep them disabled until the entire batch is done.

```bash
kubectl patch application cluster -n argocd --type json -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":null}]'
kubectl patch application applications -n argocd --type json -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":null}]'
```

### Procedure (per VolSync app)

1. **Disable auto-sync on the child app**
   ```bash
   kubectl patch application <app> -n argocd --type json -p '[{"op":"replace","path":"/spec/syncPolicy/automated","value":null}]'
   ```

2. **Scale down the app**, wait for pod termination
   ```bash
   kubectl scale deployment/<app> -n <ns> --replicas=0
   kubectl wait --for=delete pod -l app=<app> -n <ns> --timeout=60s
   ```

3. **Delete old VolSync resources**
   ```bash
   kubectl delete replicationsource <app> -n <ns>
   kubectl delete replicationdestination <app>-dst -n <ns> 2>/dev/null || true
   ```

4. **Delete old PVC (with safety net)**
   ```bash
   PV=$(kubectl get pvc <app> -n <ns> -o jsonpath='{.spec.volumeName}')
   kubectl patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   kubectl delete pvc <app> -n <ns>
   ```

5. **Update manifests in a single commit**, then push:
   - In `<app>/kustomization.yaml`: temporarily remove the `dataSourceRef` removal patch (needed so PVC is created with `dataSourceRef` pointing to the ReplicationDestination snapshot)
   - In `<app>-app.yaml`: change env vars:
     ```yaml
     VOLSYNC_STORAGECLASS: linstor
     VOLSYNC_SNAPSHOT_CLASS: linstor-snapshot
     VOLSYNC_CLEANUP_TEMP_PVC: "true"
     ```
   - In `<app>-app.yaml`: add `ignoreDifferences` for PVC dataSourceRef/dataSource + `RespectIgnoreDifferences=true` in syncOptions

   **PAUSE after push** — wait ~30s for ArgoCD to settle before proceeding.

6. **Sync through the ArgoCD chain** (order matters):
   ```bash
   argocd app get applications --hard-refresh --grpc-web
   argocd app sync applications --grpc-web
   argocd app get <app> --hard-refresh --grpc-web
   # Child app may auto-sync at this point; if not:
   argocd app sync <app> --grpc-web
   ```

7. **Wait for restore + PVC bind**, verify app works and data is correct
   ```bash
   kubectl get pvc <app> -n <ns> -o jsonpath='{.spec.storageClassName}'  # should be "linstor"
   kubectl get pvc <app> -n <ns> -o jsonpath='{.spec.dataSourceRef.name}'  # should be "<app>-dst"
   kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/<app> -n <ns> --timeout=180s
   kubectl wait --for=condition=Ready pod -l app=<app> -n <ns> --timeout=120s
   # Verify DRBD resource exists:
   kubectl -n piraeus-system exec deploy/linstor-controller -- linstor resource list | grep <pv-name>
   ```

8. **Verify data** — check the app in a browser, confirm data is present

9. **Re-add the dataSourceRef patch** in `<app>/kustomization.yaml`, commit + push

10. **Sync through ArgoCD chain again**:
    ```bash
    argocd app get applications --hard-refresh --grpc-web
    argocd app sync applications --grpc-web
    argocd app get <app> --hard-refresh --grpc-web
    ```
    Verify: `Synced` + `Healthy`

11. **Re-enable auto-sync on child**, clean up old Longhorn PV
    ```bash
    kubectl patch application <app> -n argocd --type json -p '[{"op":"replace","path":"/spec/syncPolicy","value":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true","RespectIgnoreDifferences=true"]}}]'
    kubectl delete pv <old-pv-name>
    ```

### Migration order

| Batch | Apps | Risk | Status |
|-------|------|------|--------|
| 1 | kanboard, ntfy, homebox, thelounge | Low | ✅ Complete (2026-04-09) |
| 2 | esphome, mqtt, zwave, grafana | Medium | ✅ Complete (2026-04-09) |
| 3a | home-assistant | High | ✅ Complete (2026-04-09) |
| 3b | influxdb2 | High | ✅ Complete (2026-04-09) |
| 4 | seerr, archivebox | Medium | ✅ Complete (2026-04-09) |
| 5 | matrix, immich (custom) | Medium | Pending |
| 6 | Standalone PVC apps | Varies | Pending |

---

## Phase 5: Longhorn Decommission

**Prerequisite**: ALL apps migrated and stable for at least 1 week.

1. Verify no PVCs reference Longhorn:
   ```bash
   kubectl get pvc -A -o jsonpath='{range .items[*]}{.spec.storageClassName}{"\n"}{end}' | sort -u
   # Should not contain "longhorn"
   ```

2. Remove from ArgoCD: delete `longhorn-system/longhorn-app.yaml` reference from `kubernetes/base/infra/kustomization.yaml`

3. Set LINSTOR as default StorageClass

4. Clean up NixOS: disable/remove `longhornSupport`, remove iSCSI config if unused

5. Delete Longhorn data: `rm -rf /var/lib/rancher/longhorn` on all nodes

6. Delete repo files: `kubernetes/base/infra/longhorn-system/`

7. Update volsync-v2 default comments to reference `linstor`

---

## Rollback

### Per-app rollback

Revert the app manifest to Longhorn values, delete the LINSTOR PVC and ReplicationDestination, push/sync — VolSync restores from the same S3 backup into a new Longhorn PVC.

### Full rollback

Longhorn is never modified until Phase 5. Revert all migrated apps, delete the Piraeus ArgoCD Application, revert NixOS configs. Everything goes back to how it was.

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| DRBD module issue on specific kernel | Low | High | Verified in nixpkgs; test on one node first |
| Piraeus satellite can't find NixOS binaries | Medium | Medium | PATH patch in LinstorCluster CR |
| VolSync restore fails into LINSTOR PVC | Low | Low | S3 backups intact, retry or rollback |
| envsubst empty variable breaks VolSync | High if bad sequencing | High | Single atomic commit |
| LVM thin pool full | Medium | High | Monitor via Prometheus; LINSTOR metrics |

---

*Created: 2026-04-08*
*Last Updated: 2026-04-09*
