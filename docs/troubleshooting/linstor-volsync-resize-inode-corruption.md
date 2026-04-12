# LINSTOR VolSync Snapshot Clone — resize_inode Corruption

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

Run `tune2fs -O ^resize_inode` on every LINSTOR LV across all storage nodes (opi01, opi02, opi03):

```bash
for sat in linstor-satellite.opi01-XXXXX linstor-satellite.opi02-XXXXX linstor-satellite.opi03-XXXXX; do
  kubectl exec -n piraeus-system $sat -- bash -c '
    for lv in $(lvs --noheadings -o lv_name linstor_vg | grep -v snapshot | grep "^  pvc-"); do
      lv=$(echo $lv | xargs)
      dev="/dev/linstor_vg/$lv"
      if tune2fs -l "$dev" 2>/dev/null | grep -q resize_inode; then
        echo "Removing resize_inode from $lv"
        tune2fs -O ^resize_inode "$dev"
      fi
    done
  '
done
```

The `e2fsck -f` that `tune2fs` recommends will run automatically the next time each clone PVC is mounted by the CSI driver.

### Verify the fix

```bash
kubectl exec -n piraeus-system linstor-satellite.opi01-XXXXX -- bash -c '
  for lv in $(lvs --noheadings -o lv_name linstor_vg | grep -v snapshot | grep "^  pvc-"); do
    lv=$(echo $lv | xargs)
    if tune2fs -l "/dev/linstor_vg/$lv" 2>/dev/null | grep -q resize_inode; then
      echo "STILL HAS resize_inode: $lv"
    fi
  done
  echo "Check complete."
'
```

### For new PVCs

The `linstor` StorageClass has been updated with `linstor.csi.linbit.com/fsopts: "-O ^resize_inode"` in `kubernetes/base/infra/piraeus/resources/storage-class.yaml`. This passes `-O ^resize_inode` to `mkfs.ext4` at format time, so all new PVCs are created without the feature. No manual intervention needed for new apps.

## Emergency Recovery

When a VolSync backup is stuck due to this issue:

```bash
# 1. Find the stuck mover pod
kubectl get pods -n <namespace> | grep volsync-src-<app>

# 2. Parallel-delete the stuck pod, clone PVC, and VolumeSnapshot
# (all three must be deleted simultaneously to avoid finalizer deadlocks)
kubectl delete pod <mover-pod> -n <namespace> &
kubectl delete pvc volsync-<app>-src -n <namespace> &
kubectl delete volumesnapshot volsync-<app>-src -n <namespace> &
wait

# 3. Trigger a fresh sync
kubectl annotate replicationsource <app> -n <namespace> \
  volsync.backube/manual=fix-$(date +%s) --overwrite

# 4. Verify the new mover pod starts and completes
kubectl get pods -n <namespace> -w | grep volsync-src-<app>
```

## Important Note on Crash Consistency

Disabling `resize_inode` eliminates the most common corruption vector, but does **not** make snapshots application-consistent. Other ext4 metadata could theoretically be caught mid-write. For truly consistent backups, consider:

- **VolSync `moverSecurityContext` with pod suspension** — stops the workload during backup
- **Application-level quiesce** — for databases, use native backup APIs before triggering snapshots

In practice, with `resize_inode` disabled, the remaining crash-consistency risk is very low for typical workloads (ext4 journaling handles the rest).

## Timeline

- **2026-04-08**: LINSTOR/Piraeus stack deployed, apps migrated from Longhorn via VolSync restore
- **2026-04-10**: First occurrence — homebox VolSync backup mover stuck with `Resize inode not valid`
- **2026-04-12**: Root cause identified — missing fsfreeze in CSI snapshot path + resize_inode vulnerability
- **2026-04-12**: Fix applied — `resize_inode` disabled on all LINSTOR LVs across opi01/02/03
