# NFS PV to Longhorn + VolSync Migration (Issue #34)

## Overview

Migrate 4 remaining NFS-backed apps to Longhorn with volsync-v2 backups.
NFS from possum.internal causes sqlite issues and adds a dependency on possum for the K8s cluster.

## Progress

- [x] **zwave** — migrated 2026-02-11, first backup successful (2393 files, 59 MiB)
- [x] **grafana** — migrated 2026-02-11, first backup successful (329 files, 64.6 MiB)
- [x] **home-assistant** — migrated 2026-02-11, first backup successful (57 files, 1.2 MiB)
- [x] **influxdb2** — migrated 2026-02-11, first backup successful (12725 files, 4.7 GiB)
- [ ] Clean up: delete old NFS data from possum (after all apps confirmed stable)

## Sizing

| App | Used | Old NFS | New Longhorn |
|-----|------|---------|--------------|
| zwave | 38 MB | 10Gi | 1Gi |
| grafana | 37 MB | 10Gi | 1Gi |
| home-assistant | 1 MB | 100Gi | 1Gi |
| influxdb2 | 4.1 GB | 30Gi | 10Gi |

All apps use Bitwarden item `b45f65b2-6326-42b8-b159-0e630fd223db` for S3 credentials.

## Runtime Migration Procedure (per app)

1. Disable ArgoCD auto-sync top-down (cluster → applications → app) via `kubectl patch` (argocd CLI has OCI registry validation issues)
2. Scale down: `kubectl scale deployment/<name> -n home-automation --replicas=0`
3. Create new Longhorn PVC manually
4. Copy data via temp pod (old mount read-only)
5. Verify file counts/sizes match
6. Push code changes and sync ArgoCD
7. Verify app is running and accessible
8. Wait for first volsync backup success
9. Re-enable auto-sync
10. Delete old NFS PV/PVC from k8s (NFS data on possum stays)

See the approved plan for detailed kubectl commands.

## Lessons Learned

- **All volsync env vars must be explicit.** The volsync-v2 component templates use `${ARGOCD_ENV_*}` directly and `envsubst` replaces unset variables with empty strings. The "optional, default: X" comments in the component are documentation only — not real defaults. Always set: `APP`, `VOLSYNC_CAPACITY`, `VOLSYNC_BITWARDEN_KEY`, `VOLSYNC_STORAGECLASS`, `VOLSYNC_ACCESSMODE`, `VOLSYNC_CACHE_CAPACITY`, `VOLSYNC_SCHEDULE`, `VOLSYNC_UID`, `VOLSYNC_GID`.
- **Disable auto-sync top-down.** The `cluster` app self-heals `applications`, which self-heals child apps. Must disable all three: cluster → applications → child.
- **Use `kubectl patch` not `argocd app set`.** The argocd CLI validates the full app spec on `set`, which fails for OCI Helm repos behind auth. Use `kubectl patch application -n argocd --type json` instead.
- **Sync order matters for multi-source.** After pushing code: sync `applications` first (to update the child app spec), then hard-refresh the child app (to regenerate CMP manifests), then sync the child.
- **dataSourceRef patch needs `'\$\{'` regex for apps with multiple PVCs.** Kustomize runs before envsubst, so the volsync PVC name is `${ARGOCD_ENV_APP}`. Using `name: .*` would also target other PVCs (e.g., `influxdb2-backup-pvc`) and fail on `op: remove` if they lack dataSourceRef.
- **Manually-created PVCs conflict with volsync template.** The volsync component PVC includes dataSourceRef, but manually-created PVCs don't. Since PVC spec is immutable, use `ignoreDifferences` + `RespectIgnoreDifferences=true` to skip the diff during sync.
- **Watch out for `--force` on PVCs.** Force sync can trigger delete/recreate of PVCs, losing data. If this happens, immediately set the PV reclaimPolicy to Retain before the PVC terminates.
