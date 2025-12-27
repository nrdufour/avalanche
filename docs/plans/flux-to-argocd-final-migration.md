# Flux to ArgoCD Migration - Completion Report

**Created**: 2025-12-26
**Completed**: 2025-12-27
**Status**: ✅ **COMPLETE** - All phases finished, Flux fully removed
**Result**: Zero-downtime migration of 6 applications + complete Flux removal

## Summary

Successfully migrated all remaining Flux-managed applications to ArgoCD using an "adopt-in-place" strategy that ensured zero downtime for all services. Migration completed in 2 days including full Flux removal.

### Applications Migrated (6 total)

| App | Type | Storage | Criticality | Result |
|-----|------|---------|-------------|--------|
| kanboard | VolSync | Longhorn PVC (200Mi) | Medium | ✅ Zero downtime |
| zwave | Helm | Static NFS PV (10Gi) | Medium | ✅ Zero downtime |
| mqtt | VolSync | Longhorn PVC (100Mi) | High | ✅ Zero downtime |
| esphome | Helm + VolSync | Longhorn PVC (100Mi) | High | ✅ Zero downtime |
| archivebox | VolSync | Longhorn PVC (2Gi) | Medium | ✅ Zero downtime |
| home-assistant | CNPG + NFS | PostgreSQL + Static NFS PV | **CRITICAL** | ✅ Zero downtime |

## Migration Timeline

**2025-12-26**:
- ✅ Phase 1: Preparation (backups, snapshots, secret migration to Bitwarden)
- ✅ Phase 2: kanboard and zwave migration (~2 hours)
- ✅ Phase 3: mqtt, esphome, archivebox migration (~2 hours)
- ✅ Phase 4: home-assistant migration (~2 hours)

**2025-12-27**:
- ✅ Phase 5.1: Verified cnpg-minio-access secrets already migrated to ExternalSecrets
- ✅ Phase 5.2: Set prune: false on Flux Kustomizations (commit bbe9c4e)
- ✅ Phase 5.3: Deleted all Flux Kustomizations from cluster
- ✅ Phase 5.4: Uninstalled Flux completely (`flux uninstall --namespace=flux-system`)
- ✅ Phase 5.5: Removed kubernetes/kubernetes/ directory (341 files, commit c9256dd)
- ✅ Phase 5.6: Updated documentation (CLAUDE.md, README.md)

**Total Duration**: 2 days

## Migration Strategy: Adopt-in-Place

The key to zero-downtime migration was the "adopt-in-place" approach:

1. **Set prune: false** in Flux Kustomization (prevents resource deletion)
2. **Orphan resources** by removing Flux reference from parent kustomization
3. **Prepare ArgoCD manifests** with ExternalSecrets replacing SOPS
4. **Apply ArgoCD Application** - adopts orphaned resources without recreation
5. **Verify** pod uptime, VolSync backups, CNPG databases all healthy

**Critical Rule**: Resources must be orphaned BEFORE ArgoCD becomes aware of them to prevent management conflicts.

## Key Achievements

- ✅ **Zero downtime**: No pods restarted during migration
- ✅ **VolSync continuity**: All backups preserved and working (4 apps)
- ✅ **CNPG safety**: PostgreSQL databases migrated safely with WAL archiving
- ✅ **Flux removal**: Completely uninstalled, no residual resources
- ✅ **ArgoCD-only**: 50+ applications now managed exclusively by ArgoCD

## Issues Encountered & Resolutions

1. **VolSync CA certificates**: Use `configMapName` not `secretName` for public CAs
2. **VolumeSnapshot class**: Use `longhorn-snapshot-vsc` not bare `longhorn`
3. **ExternalSecret conflicts**: Remove `dataFrom` when using explicit `data` mappings
4. **Helm + VolSync**: Use ArgoCD multiple sources feature
5. **Manual trigger cleanup**: Remove manual triggers after testing to restore schedules

## Outstanding Tasks

1. ⏳ **Delete manual volume snapshots** (created 2025-12-26, wait 1 week for stability)
   ```bash
   kubectl delete volumesnapshot -n home-automation esphome-pre-argocd-migration
   kubectl delete volumesnapshot -n home-automation mqtt-pre-argocd-migration
   kubectl delete volumesnapshot -n media archivebox-pre-argocd-migration
   kubectl delete volumesnapshot -n self-hosted kanboard-pre-argocd-migration
   ```

2. ⏳ **Investigate home-assistant CNPG scheduled backups** (last ran 2025-09-25)
   - WAL archiving working perfectly (continuous backups every 3-5 minutes)
   - Scheduled full backups not running - needs investigation
   - Low priority: WAL archiving provides point-in-time recovery

## Final Infrastructure State

**GitOps**: ArgoCD only (Flux completely removed)

**Manifests**:
- ArgoCD: `kubernetes/base/` and `kubernetes/clusters/`
- Flux: Removed (`kubernetes/kubernetes/` deleted)

**Applications**: 50+ apps managed by ArgoCD
- Apps: AI, home automation, media, self-hosted, games, IRC
- Infrastructure: cert-manager, longhorn, CNPG, ingress, observability, security

**Secrets**: ExternalSecrets (Bitwarden) + SOPS for sensitive configs

## Documentation Updates

- ✅ CLAUDE.md: Removed Flux references, updated to "ArgoCD only"
- ✅ README.md: Updated GitOps section, removed flux commands
- ✅ This document: Comprehensive migration record

## Lessons Learned

1. **Adopt-in-place works perfectly** for zero-downtime migrations
2. **ExternalSecrets v1** is the current API (not v1beta1)
3. **VolSync CA certs** belong in ConfigMaps (public certificates)
4. **Always clean up manual triggers** after testing scheduled syncs
5. **ArgoCD multiple sources** enable Helm charts with additional manifests
6. **Git history is sufficient** - no need to archive before deletion

---

**Migration Result**: ✅ **100% Success**
**Downtime**: 0 seconds
**Data Loss**: 0 bytes
**Flux Status**: Fully removed from cluster and repository
