# LINSTOR VolSync Snapshot Clone — resize_inode Corruption

> **⚠️ HISTORICAL — LINSTOR decommissioned 2026-04-29.** One of many filesystem corruption issues that made LINSTOR more trouble than it was worth. Kept for reference.

## Problem

VolSync backup mover pods get stuck in `ContainerCreating` indefinitely when the LINSTOR CSI driver creates a snapshot clone PVC for the restic backup. The kubelet reports:

```
MountVolume.SetUp failed for volume "pvc-XXXX":
  rpc error: code = Internal desc = NodePublishVolume failed ...
  failed to run fsck on device '/dev/drbdNNNN':
  /dev/drbdNNNN: Resize inode not valid.
  /dev/drbdNNNN: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
  exit status 4
```

The mover pod retries every ~2 minutes but never succeeds. The ReplicationSource stays in `SyncInProgress` forever because the mover Job is still "running" (not failed). VolSync cannot clean up or retry.

## Root Cause

### The crash-consistency gap

The LINSTOR CSI driver (piraeus-csi) does **not** freeze the filesystem before taking a VolumeSnapshot. This has been verified against every version from v0.6.0 through v1.10.6 — the feature has never existed.

The snapshot flow is:

1. Kubernetes `csi-snapshotter` sidecar sends `CreateSnapshot` gRPC to the CSI **controller**
2. The controller tells LINSTOR to create an LVM thin snapshot on the storage node
3. The filesystem is **never frozen** — the controller has no access to the mounted filesystem (that's on the CSI **node** plugin, which is not involved in snapshot creation)

This produces **crash-consistent** snapshots — equivalent to a sudden power loss. Most of the time, ext4 journal recovery handles this cleanly at mount time.

### Why resize_inode breaks

The `resize_inode` feature (ext4 inode 7) reserves space for future online filesystem resizing. This metadata structure spans multiple blocks and is occasionally updated during normal ext4 operations (block group descriptor management, inode table expansion).

When a thin LVM snapshot captures the filesystem mid-write to the resize inode, the cloned filesystem has a structurally inconsistent resize_inode. Unlike journal-recoverable inconsistencies, this is a **metadata structural error** that `e2fsck -p` (preen mode, what the LINSTOR CSI runs at mount) refuses to auto-fix — it exits with code 4 ("manual intervention required").

### Why it's intermittent

The resize_inode is only updated during specific ext4 metadata operations. Most snapshots capture a quiescent state. But when a snapshot coincides with a resize_inode update, the clone inherits the corrupt half-written metadata.

### Why retries work

Deleting the corrupt clone PVC + VolumeSnapshot and triggering a fresh sync forces VolSync to take a new VolumeSnapshot at a different point in time, which typically captures a consistent state.

## Impact

- **Affected**: Any LINSTOR-backed PVC with ext4 and `resize_inode` enabled (all of them by default)
- **Symptom**: VolSync backup mover pods stuck in `ContainerCreating` for hours/days
- **Data risk**: None — the live PVC and its data are unaffected. Only the backup clone is corrupt. Backup staleness increases until fixed.

## Solution: Disable resize_inode

The `resize_inode` feature is vestigial on LINSTOR thin-provisioned volumes:

- **Online ext4 resize** (`resize2fs`) is not used — PVC resizing is handled by LINSTOR/CSI at the block level, which creates a new LV
- **Removing it eliminates this specific corruption vector** with zero operational impact
- The feature flag can be cleared on mounted filesystems

### Apply the fix

**Both steps below are required.** Running `tune2fs -O ^resize_inode` alone is **not sufficient** — it clears the feature flag in the superblock but leaves `s_reserved_gdt_blocks > 0` on disk. `e2fsck -p` (preen mode, what the LINSTOR CSI runs at mount time) refuses to auto-fix that mismatch and exits 4, so the mover pod still gets stuck. You must also run `e2fsck -fy` offline, which zeroes the stale reserved GDT blocks and rewrites the block group descriptors to match.

Additionally, `e2fsck -fy` must operate on the DRBD device (`/dev/drbdNNNN`), not the underlying LVM volume directly — bypassing DRBD would desync replicas. That means the resource must be promoted Primary on exactly one node while no workload has it attached.

**Per-volume procedure** (must be done while the app is scaled to zero and no mover pod has the source cloned):

```bash
# 1. On one satellite, promote DRBD primary, rewrite, demote.
#    Find the minor with: drbdadm dump <resource> | grep minor
kubectl exec -n piraeus-system linstor-satellite.opi01-XXXXX -- bash -c '
  RES=pvc-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
  DEV=/dev/drbdNNNN
  drbdadm resume-io $RES 2>/dev/null   # clears any suspended:user state from earlier failed attempts
  drbdadm primary $RES                 # requires: no peer is Primary, no host mount
  tune2fs -O ^resize_inode $DEV        # clear feature flag
  e2fsck -fy $DEV                      # rc=1 is normal: "FILE SYSTEM WAS MODIFIED"
  dumpe2fs -h $DEV 2>/dev/null | grep -E "resize_inode|Reserved GDT"   # should print nothing → clean
  drbdadm secondary $RES
'
```

**Both source and cache must be fixed.** Each VolSync app has two broken filesystems: the source PVC (`<app>`) and the mover cache PVC (`volsync-src-<app>-cache`). The cache is formatted once at provisioning and inherits the same `resize_inode` defaults, so it exhibits the same inconsistency and will block the mover at `MountVolume.SetUp failed … Resize_inode not valid`.

**Common failure modes during the fix:**

- `Multiple primaries not allowed` — another node still has the resource Primary (usually because a pod is still `Terminating` or kubelet hasn't released the mount yet). Wait for termination, re-check `drbdsetup status <resource>`, then retry.
- `Device is held open by someone` with phantom PIDs — stale `open_cnt` left behind by kubelet. Check `/var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/<pvc>/mount` on the satellite host.
- RWX (NFS) PVCs — LINSTOR exports RWX volumes via the `linstor-csi-nfs-server` daemonset, which keeps the volume mounted on the export node even after the consuming app is scaled to zero. These cannot be fixed with the above procedure without also disrupting the NFS export.
- `suspended:user blocked:upper` — leftover from a failed previous attempt. `drbdadm resume-io <resource>` clears it.
- Multi-volume resources — a LINSTOR resource can expose multiple DRBD volumes (e.g. `volume:0`, `volume:1` in `drbdsetup status`). `drbdadm dump <resource>` will list multiple minors. All of them need the same `tune2fs` + `e2fsck` treatment.

### Verify the fix

For each fixed resource, check via the DRBD device (not the raw LV — the LV view can be stale while DRBD holds uncommitted writes):

```bash
kubectl exec -n piraeus-system linstor-satellite.opi01-XXXXX -- bash -c '
  RES=pvc-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
  DEV=/dev/drbdNNNN
  drbdadm primary $RES
  dumpe2fs -h $DEV 2>/dev/null | grep -E "resize_inode|Reserved GDT" && echo DIRTY || echo CLEAN
  drbdadm secondary $RES
'
```

A clean filesystem prints `CLEAN` (no `resize_inode` feature flag in the features list, no non-zero `Reserved GDT blocks` line).

To scope the remaining work across all nodes (LV-level scan — good enough for discovery, but confirm individual fixes via DRBD as above):

```bash
for sat in linstor-satellite.opi01-XXXXX linstor-satellite.opi02-XXXXX linstor-satellite.opi03-XXXXX; do
  kubectl exec -n piraeus-system $sat -- bash -c '
    for lv in $(lvs --noheadings -o lv_name linstor_vg 2>/dev/null | grep "pvc-" | grep -v snapshot); do
      lv=$(echo $lv | xargs); dev="/dev/linstor_vg/$lv"
      has_ri=$(tune2fs -l "$dev" 2>/dev/null | grep -c resize_inode)
      rgdt=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: "/Reserved GDT blocks/ {gsub(/ /,\"\",\$2); print \$2}")
      [ "$has_ri" = "0" ] && [ -n "$rgdt" ] && [ "$rgdt" != "0" ] && echo "BROKEN $lv rgdt=$rgdt"
    done'
done
```

### For new PVCs

The `linstor` StorageClass has been updated with `linstor.csi.linbit.com/fsopts: "-O ^resize_inode"` in `kubernetes/base/infra/piraeus/resources/storage-class.yaml`. This passes `-O ^resize_inode` to `mkfs.ext4` at format time, so all new PVCs are created without the feature. No manual intervention needed for new apps.

**Note on StorageClass recreation:** Kubernetes `StorageClass.parameters` is an immutable field. When updating `fsopts` (or any other parameter), the existing StorageClass must be deleted and recreated — an in-place `kubectl apply` will fail with `parameters: Forbidden: updates to parameters are forbidden`. Deleting the StorageClass is safe: existing PVCs/PVs reference it by name but don't depend on it staying alive. ArgoCD will recreate it on the next sync. The initial rollout of this fix required running `kubectl delete sc linstor` before the sync could proceed.

### Volume Expansion Compatibility

Disabling `resize_inode` does **not** break PVC expansion. Verified on 2026-04-12 with a test PVC expanded from 1 GiB to 2 GiB:

- **How LINSTOR CSI expansion actually works**: When a PVC is resized, the CSI controller expands the underlying LV at the block layer immediately. The filesystem resize is deferred to the next pod start — the PVC enters the `FileSystemResizePending` condition with message "Waiting for user to (re-)start a pod to finish file system resize of volume on node."
- **Why this is offline from ext4's perspective**: The filesystem is unmounted during the pod restart, so `resize2fs` runs offline. Offline `resize2fs` does not need `resize_inode` or `meta_bg` — it can freely allocate new GDT blocks because nothing else is using the filesystem.
- **Result**: Expansion succeeds cleanly. Data is preserved. No special filesystem features required.

This means the fix has no downside for volume sizing operations. The pod-restart requirement is a LINSTOR CSI behavior, not a consequence of removing `resize_inode`.

## Emergency Recovery

Two distinct recovery paths depending on whether the underlying source filesystem is already clean:

### Path A — source FS is clean (quick, no downtime)

Applies when the source and cache LVs are already fixed (no `resize_inode`, `Reserved GDT blocks = 0`) and the stuck mover is a one-off from a prior bad state: deleting the temp snapshot clone is enough.

```bash
# 1. Parallel-delete the stuck pod, clone PVC, and VolumeSnapshot
#    (all three must be deleted simultaneously to avoid finalizer deadlocks)
kubectl delete -n <namespace> pod/<mover-pod> pvc/volsync-<app>-src volumesnapshot/volsync-<app>-src --wait=false

# 2. Trigger a fresh sync
kubectl annotate replicationsource <app> -n <namespace> \
  volsync.backube/manual=fix-$(date +%s) --overwrite

# 3. Verify the new mover pod starts and completes
kubectl get pods -n <namespace> -w | grep volsync-src-<app>
```

### Path B — source FS still dirty (requires per-app downtime)

Applies when the underlying LV still has `resize_inode` cleared but `Reserved GDT blocks > 0` (the state left behind by an incomplete `tune2fs`-only remediation). Every fresh snapshot will inherit the dirty metadata, so the mover will keep getting stuck until the source and cache filesystems are rewritten offline.

```bash
# 1. Disable ArgoCD auto-sync so scale-down sticks
#    (argocd CLI may fail on OCI repo validation; use kubectl patch)
kubectl patch app -n argocd <app> --type json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

# 2. Scale the workload to zero and wait for the pod to fully terminate
kubectl scale -n <namespace> deploy/<app> --replicas=0
kubectl wait -n <namespace> --for=delete pod -l app.kubernetes.io/name=<app> --timeout=120s

# 3. Clear any stuck mover pod + temp clone PVC + VolumeSnapshot
kubectl delete -n <namespace> pod/<mover-pod> pvc/volsync-<app>-src volumesnapshot/volsync-<app>-src --wait=false

# 4. Confirm the source LV is fully Unused (no role:Primary anywhere)
kubectl exec -n piraeus-system linstor-satellite.opi01-XXXXX -- drbdsetup status <resource>

# 5. Run the per-volume fix from "Apply the fix" above on BOTH the source and the
#    volsync-*-cache resource. Source minor and cache minor can be found with:
#      drbdadm dump <resource> | grep minor

# 6. Scale back up, re-enable auto-sync, trigger a fresh sync
kubectl scale -n <namespace> deploy/<app> --replicas=1
kubectl patch app -n argocd <app> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl annotate replicationsource <app> -n <namespace> \
  volsync.backube/manual=fix-$(date +%s) --overwrite
```

**Warning about app-of-apps:** if a parent ArgoCD application manages the child app-of-apps, it will re-enable auto-sync on the child within seconds. Disable auto-sync on the parent first, then on the child.

**Warning about RWX (NFS) PVCs:** resources backed by the `linstor-csi-nfs-server` daemonset stay mounted on the export node even after the consuming app is scaled to zero. The fix above will fail with `Device is held open by someone` showing stale `open_cnt`. A different procedure (restarting the NFS server pod on the holding node, which briefly disrupts all RWX exports from that node) is required — handle case-by-case.

## Important Note on Crash Consistency

Disabling `resize_inode` eliminates the most common corruption vector, but does **not** make snapshots application-consistent. Other ext4 metadata could theoretically be caught mid-write. For truly consistent backups, consider:

- **VolSync `moverSecurityContext` with pod suspension** — stops the workload during backup
- **Application-level quiesce** — for databases, use native backup APIs before triggering snapshots

In practice, with `resize_inode` disabled, the remaining crash-consistency risk is very low for typical workloads (ext4 journaling handles the rest).

## Timeline

- **2026-04-08**: LINSTOR/Piraeus stack deployed, apps migrated from Longhorn via VolSync restore
- **2026-04-10**: First occurrence — homebox VolSync backup mover stuck with `Resize inode not valid`
- **2026-04-12**: Root cause identified — missing fsfreeze in CSI snapshot path + resize_inode vulnerability
- **2026-04-12**: First remediation attempt — `tune2fs -O ^resize_inode` applied cluster-wide. Incomplete: only cleared the feature flag, left `s_reserved_gdt_blocks > 0`, which `e2fsck -p` at mount time still rejects.
- **2026-04-13**: Cascade — every LINSTOR-backed VolSync ReplicationSource (11 apps) stuck within a single sync cycle as soon as a snapshot clone tried to mount.
- **2026-04-13**: Full remediation — per-app offline procedure (`tune2fs -O ^resize_inode` + `e2fsck -fy` on the DRBD device while primary) applied to archivebox, seerr, thelounge, esphome, grafana, zwave, homebox, ntfy, mqtt, home-assistant, influxdb2 (source + cache each). kanboard skipped because it's RWX-over-NFS and the NFS server daemonset holds the export mount — needs a separate procedure.
