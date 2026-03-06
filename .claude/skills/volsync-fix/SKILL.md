---
name: volsync-fix
description: Detect and unblock stuck VolSync ReplicationSource objects. Use when the user asks to check volsync status, fix stuck replications, or unblock volsync backups.
allowed-tools: Bash, AskUserQuestion
---

# VolSync Fix

Detect and fix stuck VolSync ReplicationSource objects in the Kubernetes cluster.

## Detection

A ReplicationSource is stuck when:
- Its `nextSyncTime` is in the past (sync should have happened but didn't)
- Its condition shows `Synchronizing` with message `Synchronization in-progress` for an extended period
- Its mover pod (`volsync-src-<name>-*`) is stuck in `ContainerCreating` or `Error`

Common root cause: the snapshot-restored Longhorn volume has a replica stuck in `stopped` state, so the PVC never attaches.

## Procedure

### 1. List all ReplicationSources and identify stuck ones

```bash
kubectl get replicationsource -A -o wide
```

Look for any where `NEXT SYNC` is in the past or `LAST SYNC` is abnormally old compared to others.

### 2. For each stuck ReplicationSource, confirm the issue

```bash
# Check mover pod status
kubectl get pods -n <namespace> -l app.kubernetes.io/created-by=volsync

# If a pod is stuck in ContainerCreating, check why
kubectl describe pod <pod-name> -n <namespace>
```

The typical error is `FailedAttachVolume` with message "volume is not ready for workloads".

### 3. Fix: delete the stuck mover pod, snapshot PVC, and VolumeSnapshot

```bash
# Delete the stuck mover pod
kubectl delete pod <pod-name> -n <namespace>

# Delete the snapshot-restored PVC (named volsync-<app>-src)
kubectl delete pvc volsync-<app>-src -n <namespace>

# Delete the VolumeSnapshot (named volsync-<app>-src)
kubectl delete volumesnapshot volsync-<app>-src -n <namespace>
```

All three must be deleted so VolSync creates a fresh snapshot on the next sync cycle. Deleting only the pod will recreate it against the same stuck PVC.

### 4. Verify recovery

```bash
kubectl get replicationsource <name> -n <namespace> -o wide
```

Confirm `NEXT SYNC` is now a future time. The ReplicationSource should show condition "Waiting for next scheduled synchronization".

## Behavior

1. If the user asks to **check** or **list** volsync status, run step 1 and report findings.
2. If stuck ReplicationSources are found (or the user asks to fix them), confirm which ones are stuck, then apply step 3 for each.
3. After fixing, verify recovery with step 4.
4. If the mover pod is stuck for a reason other than `FailedAttachVolume` / volume not ready, investigate further before applying the fix — use AskUserQuestion if the cause is unclear.

## Important

- **Never force-delete PVCs** — this can orphan Longhorn volumes and risk data loss.
- The PVCs being deleted (`volsync-<app>-src`) are temporary snapshot copies, NOT the application's actual data PVC.
- The application's primary PVC (e.g., `influxdb2`, `esphome`) is never touched by this procedure.
- Set `timeout: 120000` on Bash calls — PVC deletion may block while Longhorn cleans up the volume.
