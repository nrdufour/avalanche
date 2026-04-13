# Piraeus CSI Snapshot Consistency — Analysis & Path Forward

**Status**: Known issue, symptom remediated (after one botched attempt), root cause unsolved.
**Last updated**: 2026-04-13
**Owner**: none assigned (work deferred)
**Related**: [linstor-volsync-resize-inode-corruption.md](../../troubleshooting/linstor-volsync-resize-inode-corruption.md)

---

## TL;DR

The Piraeus/LINSTOR CSI driver (all versions through v1.10.6) takes **crash-consistent** volume snapshots — not application-consistent. It does not call `fsfreeze`, does not sync the filesystem, and does not issue any `FIFREEZE` ioctl before asking LINSTOR to create a thin LVM snapshot. This is a real gap in the driver, not a misconfiguration on our end.

We've observed one concrete symptom from this gap: ext4 `resize_inode` metadata corruption in VolSync snapshot clones, causing `e2fsck -p` to fail and VolSync mover pods to get stuck in `ContainerCreating` for days. We've remediated that specific symptom (the full procedure — including what we learned the hard way — is in the "What We've Done So Far" section below). But the underlying crash-consistency race is still there and could theoretically surface as different metadata corruption in the future.

**There is no community solution to copy-paste.** No GitHub issues filed, no workaround scripts, no Helm charts, no operators. If we want a real fix, we'd be the first to build it — but we do have the right hook point to build on: VolSync's `copy-trigger` annotation protocol.

This document captures everything learned across 2026-04-10 through 2026-04-13 so the knowledge isn't lost.

---

## Background: What Actually Happened

On 2026-04-10, the `homebox` VolSync backup got stuck. The mover pod was in `ContainerCreating` for 44 hours. Kubelet was retrying the mount every ~2 seconds (1309 retries captured), reporting:

```
MountVolume.SetUp failed for volume "pvc-37e7be16-...":
  rpc error: code = Internal desc = NodePublishVolume failed ...
  failed to run fsck on device '/dev/drbd1021':
  /dev/drbd1021: Resize inode not valid.
  /dev/drbd1021: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
  exit status 4
```

Investigation determined:

- The live homebox PVC filesystem is **clean** (verified with `e2fsck -n`)
- The origin restore snapshot is **clean**
- Only the specific VolSync snapshot clone was corrupt
- The corruption was in ext4 inode 7 (the resize inode)
- A fresh retry (after parallel-delete of the stuck pod + clone PVC + VolumeSnapshot) succeeded

The immediate recovery procedure is documented in the troubleshooting doc. This doc covers the **why**.

---

## Why the Corruption Happens (The Causal Chain)

### The filesystem layer: ext4 `resize_inode` and metadata_csum

The `resize_inode` ext4 feature reserves a pool of "future GDT" (Group Descriptor Table) blocks at mkfs time, so that online filesystem resizing can add new block groups without needing to move existing data. Inode 7 (`EXT2_RESIZE_INO`) owns these reserved blocks via indirect block pointers.

The reserved GDT blocks, plus inode 7's indirect blocks, form a **multi-block metadata structure** that's not atomically updated. When ext4 modifies this metadata — which can happen during certain bookkeeping operations even without an actual resize — the update spans multiple disk blocks written in sequence.

With `metadata_csum` enabled (which all our filesystems have), every metadata block carries a checksum. If any block in the resize inode's structure is captured in an inconsistent state, the checksum won't match, and `e2fsck -p` bails with "Resize inode not valid" — exit code 4, "manual intervention required." Red Hat Bugzilla #156954 and #227670 both document this exact failure mode from partial metadata writes.

### The storage layer: LINSTOR thin LVM snapshots

LINSTOR's in-cluster snapshots for `LVM_THIN` storage pools are implemented via LVM thin snapshots. LVM thin snapshots are **atomic at the block level** — the DM target copies block mapping metadata on write, so a snapshot captures a point-in-time view of block contents.

But atomic-at-the-block-level is not the same as atomic-at-the-filesystem-level. If the filesystem is in the middle of writing multiple blocks (e.g., a metadata update spanning the resize inode and several GDT blocks), the snapshot might capture some blocks post-write and others pre-write. The block-level view is internally consistent (you see real bytes, not torn writes), but the filesystem-level view is not (the metadata relationships are broken).

This is the standard "crash-consistent vs application-consistent snapshot" distinction. Pulling the power cord from a running Linux box produces a crash-consistent state — ext4's journal will recover most issues on next mount, but some structural inconsistencies (like a half-updated resize inode) require manual `e2fsck`.

### The CSI layer: Piraeus does not freeze

The proper way to take a consistent snapshot of a mounted filesystem is to call `fsfreeze --freeze` (or the `FIFREEZE` ioctl) on the mount point before the snapshot, then `fsfreeze --unfreeze` after. This tells the kernel to flush all dirty pages, commit the journal, and block new writes until thawed. The resulting snapshot is application-consistent.

**Piraeus CSI v1.10.6 does none of this.** Confirmed by reading the source (`pkg/client/linstor.go` → `SnapCreate` → `Resources.CreateSnapshots(ctx, snapConfigs...)` — no preceding sync, freeze, or ioctl). The full CHANGELOG from v0.6.0 through v1.10.6 has zero occurrences of the words `freeze`, `fsfreeze`, `quiesce`, or `thaw`. This feature has never existed in any released version.

Architectural reason why it's not trivial to add: the CSI `CreateSnapshot` RPC is **controller-side**. The controller plugin has no access to the mounted filesystem — that's on the **node** plugin. A proper fsfreeze implementation needs the controller to coordinate with the node plugin (which knows the mount path) to run the freeze, then create the snapshot, then thaw. Mayastor does exactly this; Piraeus doesn't.

### Why it's intermittent

The resize inode is mostly static after mkfs. It's not constantly being rewritten. But there are occasional operations that touch it or the blocks it manages:

- Lazy initialization of block groups on first use
- Certain `metadata_csum` updates propagating to backup superblocks
- `sparse_super` maintenance

Most snapshots happen when these operations are not in flight. When one does coincide, you get the corruption. That explains the observed pattern: one failure per ~24 hours of cluster uptime, not every single backup cycle.

---

## How Other CSI Drivers Handle This

| Driver | Fsfreeze / Quiesce | Notes |
|---|---|---|
| **OpenEBS Mayastor** | ✅ `FIFREEZE`/`FITHAW` ioctls, **enabled by default** | Gold standard. Runs from the CSI node plugin. Configurable via `quiesceFs: none` to disable. |
| **Longhorn** | ✅ `fsfreeze` since v1.7.0 (Aug 2024) | Uses `FIFREEZE` via instance manager. Requires kernel ≥ 5.17. Falls back to `sync` otherwise. Issue #2187 took 4+ years from first request to implementation. |
| **Ceph RBD CSI** | ❌ No automatic fsfreeze | Documented as "user's responsibility" (issue #1532). For rbd-nbd with `quiesce` mapOption, fsfreeze hooks fire on quiesce notification, but the standard CSI path has nothing. |
| **Ceph CephFS CSI** | 🚧 In development | `subvolume quiesce` feature for multi-client IO pause. FOSDEM 2024 talk covered crash-consistent group snapshots. |
| **Piraeus/LINSTOR CSI** | ❌ **Nothing** | No `fsfreeze`, no `sync`, no ioctl, no issues filed, no PRs, no plans. |

Mayastor is the reference implementation. Their approach: run `FIFREEZE` from the **CSI node plugin** (where the volume mount path is known) before the controller plugin calls the storage backend's snapshot API.

---

## The CSI Spec's Fault (Partially)

The original Kubernetes CSI snapshot design proposal (`kubernetes/community`, commit `9adb191`, ~2018) explicitly deferred fsfreeze:

> "Goal 4: Offer application-consistent snapshots by providing pre/post snapshot hooks to freeze/unfreeze applications and/or unmount/mount file system. This will be considered at a later phase."

It is now 2026. The "later phase" has never materialized. The Kubernetes `VolumeSnapshot` API still makes no consistency guarantees. The `external-snapshotter` sidecar has no pre-snapshot hook mechanism. Volume Group Snapshots graduated to beta in K8s 1.32 and v1beta2 in 1.34, adding multi-volume point-in-time consistency but **still no fsfreeze**.

So every CSI driver that wants consistent snapshots has to implement fsfreeze out-of-band, as a driver-specific extension. Longhorn and Mayastor did. Piraeus didn't.

---

## LINSTOR's Misleading "Consistent Snapshot" Claim

LINSTOR documentation states that consistent snapshots are taken even while the resource is in active use. This is **technically true at the DRBD block level** and **false at the filesystem level**.

What LINSTOR actually provides:

- `drbdadm suspend-io` — pauses DRBD replication I/O between peers. This operates at the **block device level**. It ensures the snapshot captures a block-consistent state across all replicas (no torn writes, no mid-replication state).
- It does **not** flush the filesystem page cache
- It does **not** sync dirty journal transactions
- It does **not** block new writes to the mounted filesystem from above

From the LINBIT drbd-user mailing list (older archive):

> "If you have a busy volume, or a filesystem type that does not ensure relational consistency, you will end up with filesystem corruption when you try to snapshot the volume. If you want filesystem freezing with DRBD, you'd have to do it explicitly, such as using `xfs_freeze -f`."

The Longhorn project's own wiki investigated the same distinction: `dmsetup suspend` on a device protects the block device from further I/O, but "none of the file systems on its partitions are synced. No data in the dirty page cache is written down, so a backup of the device is not file-system consistent."

So when LINSTOR docs say "consistent," they mean "the block device view is atomic." They do not mean "your ext4 filesystem will be cleanly mountable." These are very different guarantees and the docs are not clear about the distinction.

---

## The Piraeus Maintainer Response (Issue #632)

In December 2025, someone reported ext4 corruption on CloudNative-PG volumes managed by Piraeus (piraeus-operator issue #632, "Fixing errors in the filesystem"). The maintainers' response was to add **automatic `e2fsck` before every mount** — a repair mechanism, not a prevention mechanism.

This is telling: the maintainers are aware filesystems get corrupted on their snapshots. Their fix is "automatically try to repair it on next mount." This works for cases where `e2fsck -p` can auto-repair. It does **not** work for cases like ours where `e2fsck -p` returns exit 4 ("manual intervention required"). We got the structural inconsistency flavor, which needs `e2fsck -f` (full force), which `-p` mode refuses to run.

The design choice says a lot: they've chosen to ship repair-on-mount rather than prevent-via-fsfreeze. That means upstream isn't likely to prioritize a proper fix, and if we want one, we'll probably have to build it or file an issue that motivates them.

---

## Why Velero's fsfreeze Hooks Don't Save Us

Velero has documented `fsfreeze` pre/post-hook examples, and in theory we could use Velero to back up LINSTOR volumes with application-consistent snapshots. In practice, this doesn't work: Velero GitHub issue #4268 documents a fundamental ordering problem. The CSI VolumeSnapshot is not guaranteed to be created within the pre-hook/post-hook execution window. The snapshot may happen before the pre-hook runs or after the post-hook completes, so the freeze/thaw don't actually bracket the snapshot creation.

This is a Velero architecture limitation, not something we could work around with config.

---

## The Only Viable Hook Point: VolSync `copy-trigger`

The VolSync project (v0.9.1+, documented in v0.13.0) added a feature specifically to enable external automation to gate snapshot creation: the `copy-trigger` annotation protocol. From VolSync discussion #1414, the maintainers explicitly chose not to implement fsfreeze inside VolSync itself because "they can require privileges such as being able to exec into users containers." Instead, they built an extension point so external automation can do it.

### How the protocol works

On the source PVC, set an annotation to enable the mechanism:

```yaml
metadata:
  annotations:
    volsync.backube/use-copy-trigger: ""
```

VolSync then maintains a state machine on the PVC via two annotations:

- `volsync.backube/latest-copy-status` — VolSync sets this to `WaitingForTrigger`, `InProgress`, or `Completed`
- `volsync.backube/latest-copy-trigger` — VolSync sets this to echo back the trigger value the user accepted

The user signals "take the snapshot now" by setting:

- `volsync.backube/copy-trigger` — a unique value (e.g., a timestamp) that the user updates to request a new snapshot cycle

### The flow

1. VolSync's scheduled trigger fires (cron)
2. VolSync sees `use-copy-trigger` is enabled, sets `latest-copy-status: WaitingForTrigger`, pauses (10 minute timeout)
3. External automation detects `WaitingForTrigger`, runs `fsfreeze --freeze /mount/path` inside the source pod
4. Automation sets `copy-trigger` to a fresh unique value
5. VolSync detects the new value, proceeds to create the VolumeSnapshot, sets `latest-copy-status: InProgress`
6. Automation watches for `latest-copy-status: Completed`
7. Automation runs `fsfreeze --unfreeze /mount/path`

### What still needs building

The automation layer. There is **no community-built controller** for this. We would need to build either:

**Option A: A lightweight per-app sidecar or Job**
A small script that watches the source PVC annotations, exec's into the app pod to run `fsfreeze`, sets the trigger, waits for completion, and thaws. Requires `pods/exec` RBAC. Simple but per-app boilerplate.

**Option B: A cluster-wide controller**
A single controller that watches all PVCs with `use-copy-trigger`, handles the freeze/trigger/thaw loop generically, applies label selectors to find the workload pod. Reusable across apps. More upfront work but one-time investment.

**Option C: A privileged DaemonSet**
Run a DaemonSet on all nodes that reads mount paths from the kubelet and calls `ioctl(FS_IOC_FIFREEZE)` directly on the kernel path. Doesn't need `pods/exec` or cooperation from the app pod. Most robust but highest privilege requirements and most complex to build.

Mayastor's approach is closest to Option C. For a homelab, Option B is probably the right balance.

---

## What We've Done So Far (Mitigation)

All commits are on `main`.

### Phase 1 — initial symptom remediation (2026-04-12)

1. **Recovered the stuck homebox backup** via parallel-delete of mover pod + clone PVC + VolumeSnapshot, then manual sync trigger. Recovery documented in `docs/troubleshooting/linstor-volsync-resize-inode-corruption.md`.

2. **Ran `tune2fs -O ^resize_inode` on every existing LINSTOR LV** across opi01/opi02/opi03 — intended to remove the vulnerable metadata structure cluster-wide.

3. **Updated the `linstor` StorageClass** with `linstor.csi.linbit.com/fsopts: "-O ^resize_inode"` so new PVCs are formatted without the feature from mkfs time. Tested end-to-end with a fresh PVC.

4. **Verified volume expansion still works** — tested 1 GiB → 2 GiB expansion on a test PVC without `resize_inode`. LINSTOR CSI's expansion is inherently offline-per-pod-restart (PVC enters `FileSystemResizePending` until pod is restarted), so `resize_inode` was never actually needed for resize operations.

5. **Learned that `StorageClass.parameters` is immutable** — updating `fsopts` required deleting and recreating the StorageClass. ArgoCD fails to update in place with `Forbidden: updates to parameters are forbidden`.

6. **Documented the initial root cause** in `docs/troubleshooting/linstor-volsync-resize-inode-corruption.md`.

### Phase 2 — the 2026-04-13 cascade

Phase 1 looked complete but was not. The next morning, **every single LINSTOR-backed VolSync ReplicationSource (11 apps)** was stuck within one sync cycle: `esphome`, `grafana`, `home-assistant`, `influxdb2`, `mqtt`, `zwave`, `thelounge`, `archivebox`, `seerr`, `homebox`, `ntfy`. The only LINSTOR-backed one that kept succeeding was `kanboard`, for a reason we didn't expect (see Phase 3).

**Root cause of the cascade**: `tune2fs -O ^resize_inode` only clears the superblock feature flag. It does **not** zero the on-disk structures tied to that feature — specifically `s_reserved_gdt_blocks`, which stays at its non-zero mkfs value. The resulting state (`resize_inode` feature cleared **and** `s_reserved_gdt_blocks > 0`) is precisely the flag/data mismatch that `e2fsck -p` classifies as "manual intervention required" and bails with exit 4. So the Phase 1 fix left every LV in the same inconsistent state that had previously occurred only occasionally from snapshot races — and every volume now tripped the CSI driver's mount-time fsck on its next snapshot clone.

In other words, the Phase 1 remediation converted a rare, race-dependent failure into a guaranteed, deterministic failure on every single volume. **The cluster would have been better off without the Phase 1 fix** — at least most apps would have kept working.

### Phase 3 — full remediation (2026-04-13)

The correct procedure is **both** steps, both required: `tune2fs -O ^resize_inode` **and** `e2fsck -fy`, run **offline** (app scaled to zero, no mover clone) on the **DRBD device** (not the raw LV — bypassing DRBD would desync replicas). Only `e2fsck -fy` actually zeros `s_reserved_gdt_blocks` and rewrites the block group descriptors to match the cleared feature flag.

Per-app sequence (scripted, ~5 min each):

1. Remove `spec.syncPolicy.automated` on the ArgoCD Application (and the parent app-of-apps, which otherwise re-enables its children within seconds)
2. `kubectl scale deploy/<app> --replicas=0` and wait for pod termination
3. Delete stuck mover pod + clone PVC + VolumeSnapshot (parallel)
4. Confirm the source LV is fully `Unused` on LINSTOR
5. On one satellite: `drbdadm resume-io <resource>` (clears leftover `suspended:user` state from failed attempts), `drbdadm primary <resource>`, `tune2fs -O ^resize_inode /dev/drbdNNNN`, `e2fsck -fy /dev/drbdNNNN`, `drbdadm secondary <resource>`
6. Repeat step 5 for the `volsync-<app>-cache` resource — the mover cache has the same ext4 formatting and the same vulnerability, and a stuck mover will fail to mount either the source clone **or** the cache
7. Scale deployment back to 1, re-enable auto-sync, annotate/patch the ReplicationSource to trigger a fresh manual sync
8. Verify the mover runs to `Completed` and the ReplicationSource returns to `Waiting for next scheduled synchronization`

Failure modes observed during this procedure:

- **`Multiple primaries not allowed`** from `drbdadm primary` — another node still holds the resource Primary because a pod is still `Terminating` or kubelet hasn't released its mount. Wait, re-check `drbdsetup status`, retry.
- **`Device is held open by someone`** with phantom opener PIDs from days ago — stale `open_cnt` left in the DRBD kernel state by a crashed kubelet mount. Investigate via `/var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/<pvc>/mount` on the host.
- **`suspended:user blocked:upper`** — leftover from a prior failed attempt. `drbdadm resume-io <resource>` clears it.
- **Multi-volume resources** — a single LINSTOR resource can expose multiple DRBD volumes (e.g., `volume:0`, `volume:1` in `drbdsetup status`). `drbdadm dump <resource>` lists all minors. Each one needs the same `tune2fs` + `e2fsck` treatment. `kanboard` had this: source and cache each carried two DRBD volumes.

Full per-app breakdown: 10 apps remediated end-to-end in ~2 hours (archivebox, seerr, thelounge, esphome, grafana, zwave, homebox, ntfy, mqtt, home-assistant, influxdb2 — source + cache each = 22 LVs rewritten). Detailed runbook in `docs/troubleshooting/linstor-volsync-resize-inode-corruption.md` (Path B).

### Phase 4 — kanboard and the RWX/NFS complication

`kanboard` was the only LINSTOR-backed VolSync replication that **kept succeeding** throughout the cascade. That was initially confusing — its underlying LV had exactly the same `s_reserved_gdt_blocks > 0` state as every other LV.

The answer: `kanboard`'s PVC was provisioned as `ReadWriteMany`. On LINSTOR, RWX is not a native capability — piraeus implements it by running a `linstor-csi-nfs-server` DaemonSet (Ganesha NFS) that mounts the DRBD volume on one "export node" and re-exports it over NFS to consuming pods. So the consumer pods never mount the DRBD block device directly; they mount the NFS export. And when VolSync takes a snapshot clone, that clone is also mounted via the same NFS layer, not by the CSI driver running `e2fsck -p` on the block device. **The entire fsck-at-mount failure path is bypassed for RWX volumes.** The corruption is present on-disk, but it's invisible to everything that would notice it.

This also broke the Phase 3 remediation procedure for `kanboard`: when we scaled the app to zero and tried to run `drbdadm primary` from a satellite node, it failed with `Device is held open by someone` — because `linstor-csi-nfs-server` on the export node was still holding the mount for the NFS export. No consuming pod was visible to `kubectl get pods`, and the `open_cnt` opener list reported phantom PIDs from days ago that didn't exist in the host's process table.

**Resolution**: rather than wrestle with restarting the NFS server daemonset (which would disrupt all RWX exports from the same node), we migrated `kanboard` from RWX to RWO. It was a single-replica deployment with a 200 MiB dataset that had been provisioned as RWX by accident — nothing actually required multi-writer semantics. The migration procedure (commit `263b661`, then `99000ca`):

1. Trigger a fresh backup to ensure restic has the latest state
2. Change `VOLSYNC_ACCESSMODE: ReadWriteMany` → `ReadWriteOnce` in `kanboard-app.yaml`
3. Add `strategy: { type: Recreate }` to the deployment — RWO + RollingUpdate deadlocks on pod rollouts because the new pod can't mount the PVC while the old one still holds it
4. Temporarily remove the `dataSourceRef` strip patch from `kustomization.yaml` so the replacement PVC is created with a VolSync restore pointer
5. Scale to 0, delete the old RWX PVC, sync ArgoCD → new RWO PVC provisioned with `dataSourceRef` → VolSync populator runs restore from restic → kanboard pod starts on the restored data
6. Re-add the `dataSourceRef` strip patch as a safety net

The new PVC was born without the corruption because the `linstor` StorageClass now passes `-O ^resize_inode` to `mkfs.ext4` at provisioning time. Net result: `kanboard` is now on the same direct-block backup path as every other app, and the `linstor-csi-nfs-server` daemonset is one dependency lighter in the cluster.

**Generalizable lesson**: any PVC with `ReadWriteMany` on LINSTOR silently adds an NFS-server chokepoint on one node, bypasses the ext4 fsck path entirely (both for better and for worse), and breaks the offline-fsck remediation procedure. RWX should be a deliberate choice, not an accident. Audit existing RWX PVCs; migrate any that don't actually need multi-writer semantics.

### What this mitigation does NOT fix

The underlying crash-consistency race is still there. We've removed one specific vulnerable target (the `resize_inode` feature), but nothing about the Piraeus snapshot path has changed. Other ext4 metadata structures that could theoretically hit similar corruption patterns in the future:

- **The journal itself during a transaction commit** — partial journal writes captured mid-commit
- **Block group descriptors during allocation** — `flex_bg` metadata updates
- **The superblock during mount-count updates** — less likely, but possible
- **`metadata_csum` checksum blocks on any metadata being written during the snapshot window** — this is the broadest risk

None of these have been observed in practice yet, but the mechanism is still present. The only real fix is getting `fsfreeze` into the snapshot path.

**Lesson from the cascade**: the "accept the risk, it's rare" framing looked fine until one bad remediation turned a stochastic risk into a deterministic failure across the entire cluster in a single sync cycle. Monitoring (Priority 1) is no longer optional — it should be the first thing built, independent of any decision about the deeper fix. And when modifying filesystem feature flags, the change must always include an offline `e2fsck -fy` pass, not just the `tune2fs` call (see `feedback_tune2fs_requires_fsck.md` in auto-memory).

---

## Future Work (Planned, Deferred)

### Priority 1: Monitoring + Alerting (30 minutes of work)

Build a Prometheus alert for VolSync mover pods stuck in `ContainerCreating` longer than 1 hour. Pair with the documented parallel-delete runbook (or the existing `volsync-fix` skill). This turns "mysterious corruption" into "known alert → 30-second fix."

**Implementation sketch**:

```yaml
- alert: VolSyncMoverStuck
  expr: |
    sum by (namespace, pod) (
      kube_pod_status_phase{phase="Pending"}
      * on (namespace, pod) group_left
      kube_pod_info{pod=~"volsync-src-.*"}
    ) > 0
    and on (namespace, pod)
    (time() - kube_pod_created) > 3600
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "VolSync mover pod {{ $labels.pod }} stuck in Pending for >1h"
    runbook: "docs/troubleshooting/linstor-volsync-resize-inode-corruption.md#emergency-recovery"
```

Also consider alerting on ReplicationSource staleness (`lastSyncTime` older than 2x schedule interval).

This should be done regardless of any other work on this topic.

### Priority 2: File Upstream Issue at piraeusdatastore/linstor-csi

The maintainers should know this is a real production problem. Draft talking points:

- Title: "Feature request: application-consistent snapshots via fsfreeze"
- Background: ext4 `resize_inode` corruption observed in production (cite the error message)
- Root cause: no pre-snapshot filesystem freeze
- Reference implementations: Mayastor (`FIFREEZE` ioctl from node plugin, enabled by default), Longhorn (v1.7.0, 2024)
- Reference to piraeus-operator issue #632 (their current fix is repair-on-mount, not prevention)
- Reference to the CSI spec's 2018 deferral of hook support
- Ask: is there interest in accepting a PR that implements this in the node plugin, following the Mayastor pattern?

Filing the issue is effectively free and gives upstream a chance to fix this for everyone.

### Priority 3: Build VolSync copy-trigger automation for critical apps

Scope: the apps whose data actually matters and where a backup staleness window hurts. First pass candidates:

- **homebox** — the app that started this investigation, currently the only observed failure
- **home-assistant** — irreplaceable home automation state and history
- **grafana** — dashboards and annotations
- **kanboard** — task tracking
- **n8n** — workflow automation state
- **influxdb2** — time series (already has a separate known issue documented)
- **mqtt** — if retained messages matter

Not critical (crash-consistent backups are fine):

- **archivebox** — can re-archive
- **ntfy** — ephemeral notifications
- **thelounge** — IRC scrollback, nice to have but not critical
- **esphome** — config can be regenerated
- **seerr** — request history, re-derivable
- **zwave** — devices re-pair on restore

Architecture choice: **Option B** (single cluster-wide controller) is probably the right balance. Put it in the `infra/security` or `infra/system` namespace with RBAC to `pods/exec` on the namespaces we care about, watching for `WaitingForTrigger` annotations and handling the freeze/trigger/thaw loop.

Alternatively, start simpler: **Option A** (per-app CronJob) for homebox first, prove the pattern works, then decide whether to generalize.

The per-app pattern would look like:

```yaml
# Add to source PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: homebox
  annotations:
    volsync.backube/use-copy-trigger: ""
---
# Companion CronJob
apiVersion: batch/v1
kind: CronJob
metadata:
  name: homebox-backup-freeze
spec:
  # Align with VolSync schedule but slightly before
  schedule: "55 * * * *"  # VolSync runs at :05, we run at :55
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: freeze-hook
          containers:
            - name: freeze
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  # Wait for VolSync to reach WaitingForTrigger
                  kubectl wait pvc/homebox -n self-hosted \
                    --for=jsonpath='{.metadata.annotations.volsync\.backube/latest-copy-status}=WaitingForTrigger' \
                    --timeout=600s
                  POD=$(kubectl get pod -n self-hosted -l app=homebox -o jsonpath='{.items[0].metadata.name}')
                  kubectl exec -n self-hosted "$POD" -- fsfreeze --freeze /data
                  trap 'kubectl exec -n self-hosted "$POD" -- fsfreeze --unfreeze /data || true' EXIT
                  TRIGGER="snap-$(date +%s)"
                  kubectl annotate pvc homebox -n self-hosted \
                    volsync.backube/copy-trigger="$TRIGGER" --overwrite
                  kubectl wait pvc/homebox -n self-hosted \
                    --for=jsonpath='{.metadata.annotations.volsync\.backube/latest-copy-status}=Completed' \
                    --timeout=300s
```

Caveats:

- The app container must have `fsfreeze` available. Most distroless images don't. Options: (a) use a sidecar with `util-linux`, (b) switch to a base image that includes it, (c) use the DaemonSet approach instead.
- `pods/exec` RBAC is powerful. Scope it tightly to the specific pod names.
- Timing: the VolSync `WaitingForTrigger` timeout is 10 minutes, so the CronJob has that window to run. Adjust schedule offsets carefully.
- Error handling: if the CronJob fails after freezing but before thawing, the app's filesystem is stuck frozen. The `trap` in the script above helps but isn't bulletproof. A separate "watchdog" that forcibly thaws after N minutes is worth considering.

### Priority 4: Consider `metadata_csum_seed` and other ext4 features

Beyond `resize_inode`, there are other ext4 features that could theoretically contribute to crash-consistency corruption. Worth investigating whether any of these are candidates for removal:

- `metadata_csum` — removing this reduces corruption detection but also reduces the attack surface. Probably not worth it — better to keep detection even if it makes us notice corruption.
- `64bit` — required for anything over 16 TiB. We don't need it for our small volumes, but it's tangential to the consistency issue.
- `dir_nlink`, `extra_isize`, `huge_file`, etc. — all benign, not candidates.

The most interesting follow-up would be to survey what features are set by default on Piraeus LVs vs. what features are strictly needed, and disable the rest via `fsopts`. Not a priority but something to revisit if new corruption patterns emerge.

---

## References

### Source code

- [piraeusdatastore/linstor-csi — SnapCreate (no fsfreeze)](https://github.com/piraeusdatastore/linstor-csi/blob/master/pkg/client/linstor.go)
- [piraeusdatastore/linstor-csi CHANGELOG (full history, zero fsfreeze mentions)](https://github.com/piraeusdatastore/linstor-csi/blob/master/CHANGELOG.md)

### Related Piraeus issues

- [piraeus-operator #632 — ext4 corruption on CNPG, fixed with auto-e2fsck on mount](https://github.com/piraeusdatastore/piraeus-operator/issues/632)
- [piraeus-operator #628 — unrelated resize2fs version mismatch](https://github.com/piraeusdatastore/piraeus-operator/issues/628)

### CSI spec and Kubernetes

- [CSI snapshot design proposal, fsfreeze explicitly deferred (2018)](https://github.com/kubernetes/community/blob/9adb191917a4a5e29342254f9eda7dd83a7d3802/contributors/design-proposals/storage/csi-snapshot.md)
- [Velero issue #4268 — fsfreeze pre/post hooks don't work with CSI VolumeSnapshots](https://github.com/vmware-tanzu/velero/issues/4268)

### Reference implementations (other CSI drivers)

- [Longhorn issue #2187 — fsfreeze feature request, implemented in v1.7.0](https://github.com/longhorn/longhorn/issues/2187)
- [Longhorn wiki — dmsetup suspend vs fsfreeze (block-level ≠ filesystem-level)](https://github.com/longhorn/longhorn/wiki/Freezing-File-Systems-With-dmsetup-suspend-Versus-fsfreeze)
- [OpenEBS Mayastor — FIFREEZE/FITHAW ioctls, `quiesceFs` parameter](https://openebs.io/docs/user-guides/replicated-storage-user-guide/replicated-pv-mayastor/advanced-operations/volume-snapshots)
- [Ceph-CSI issue #1532 — no fsfreeze, user's responsibility](https://github.com/ceph/ceph-csi/issues/1532)
- [FOSDEM 2024 — Crash-consistent group snapshots in CephFS](https://archive.fosdem.org/2024/schedule/event/fosdem-2024-2127-crash-consistent-group-snapshots-in-cephfs-for-k8s-csi-and-you-/)

### LINSTOR / DRBD consistency behavior

- [DRBD-user mailing list — explicit fsfreeze required with DRBD+LVM](https://drbd-user.linbit.narkive.com/QRX9BBZo/drbd-lvm-backup)

### VolSync extension point

- [VolSync PVC copy-trigger documentation](https://volsync.readthedocs.io/en/v0.13.0/usage/pvccopytriggers.html)
- [VolSync discussion #1414 — copy-trigger examples, fsfreeze deliberately not built in](https://github.com/backube/volsync/discussions/1414)

### ext4 corruption background

- [Red Hat Bugzilla #156954 — resize_inode invalid after partial metadata write](https://bugzilla.redhat.com/show_bug.cgi?id=156954)
- [Red Hat Bugzilla #227670 — related ext4 metadata corruption from partial writes](https://bugzilla.redhat.com/show_bug.cgi?id=227670)

### Adjacent (VM-specific, not directly applicable)

- [OpenNebula addon-linstor_un issue #11 — `virsh domfsfreeze` path for VM workloads](https://github.com/OpenNebula/addon-linstor_un/issues/11)

---

## Decision Log

**2026-04-12**: Mitigated the observed symptom by disabling `resize_inode` feature on all existing and new LINSTOR PVCs. Accepted the residual risk of future metadata corruption from the unfixed crash-consistency gap. Chose not to build the VolSync copy-trigger automation today due to time constraints. Documented everything in this file so the work can be picked up later without losing context.

**2026-04-13**: Learned the 2026-04-12 mitigation was incomplete. `tune2fs -O ^resize_inode` only cleared the feature flag, leaving `s_reserved_gdt_blocks > 0` on disk — the exact state `e2fsck -p` refuses to auto-fix. Every LINSTOR-backed VolSync replication (11 apps) tripped on its next sync cycle, producing a cluster-wide cascade that was worse than the original rare failure mode. Performed the full offline procedure (`tune2fs -O ^resize_inode` + `e2fsck -fy` on the DRBD device, per source + cache PVC) on all affected apps. Migrated `kanboard` from RWX to RWO along the way to sidestep the `linstor-csi-nfs-server` mount-holder complication. New lessons captured in auto-memory and in this doc's Phase 2/3/4 sections.

The cascade changed my confidence in "accept the risk" as a long-term strategy. Monitoring (Priority 1) should be built immediately and independently of any other decision — it would have caught the cascade within minutes instead of hours. The deeper `fsfreeze` fix (Priority 3) is no longer a nice-to-have; it's the only way to prevent the next class of metadata corruption from repeating this experience with a different vulnerable field.

Open questions to revisit:
- **Priority 1 (monitoring)**: should happen this week. 30 minutes of work. Do first.
- **Priority 2 (upstream issue)**: file now. The 2026-04-13 cascade gives a concrete production-severity anecdote to strengthen the case — "tune2fs-only mitigation turned a stochastic risk into a deterministic cluster-wide outage" is the kind of story maintainers take seriously. Include a link to piraeus-operator issue #632 (their repair-on-mount fix) and point out that it would not have caught our class of corruption (fsck exit 4, not auto-repairable).
- **Priority 3 shape (per-app CronJob vs cluster-wide controller)**: start with Option A (per-app CronJob) for `influxdb2` and `home-assistant` as the two highest-value targets. If that works, graduate to Option B (cluster-wide controller) once we have ≥3 apps on it and the per-app pattern is starting to feel like boilerplate.
- **Priority 4 (other ext4 features)**: lower priority, but worth doing a fsopts audit at the next convenient moment — what features are actually needed on Piraeus LVs vs what's mkfs default.
- **RWX audit**: enumerate all RWX PVCs in the cluster. For each, decide if it actually needs multi-writer semantics. Any that don't should be migrated to RWO (per the kanboard playbook) — both to simplify the backup path and to remove accidental dependencies on the `linstor-csi-nfs-server` DaemonSet.
- Does VolSync's `copyMethod: Clone` (LVM clone instead of snapshot) have different consistency characteristics? (Still not investigated.)
