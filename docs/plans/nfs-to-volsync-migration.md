# NFS PV to Longhorn + VolSync Migration (Issue #34)

## Overview

Migrate 4 remaining NFS-backed apps to Longhorn with volsync-v2 backups.
NFS from possum.internal causes sqlite issues and adds a dependency on possum for the K8s cluster.

## Progress

- [ ] **zwave** — code changes done, awaiting runtime migration
- [ ] **grafana** — code changes done, awaiting runtime migration
- [ ] **home-assistant** — code changes done, awaiting runtime migration
- [ ] **influxdb2** — code changes done, awaiting runtime migration
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

1. Disable ArgoCD auto-sync: `argocd app set applications --sync-policy none && argocd app set <app> --sync-policy none`
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
