# Flux to ArgoCD Final Migration Plan

**Created**: 2025-12-26
**Last Updated**: 2025-12-26 (Phase 1 Complete)
**Status**: ✅ Phase 1 Complete - Ready for Phase 2
**Priority**: High - Complete GitOps consolidation

## Executive Summary

This plan outlines the final migration of 6 Flux-managed applications to ArgoCD, with critical focus on data safety for apps using VolSync backups and PostgreSQL databases.

**Progress**: Phase 1 (Preparation) completed successfully. All backups verified, manual snapshots created, secrets migrated to Bitwarden.

## Current State (from cluster inspection - 2025-12-26)

### Flux-Managed Applications (6 total)

| App | Namespace | Storage Type | Backup Method | Data Criticality |
|-----|-----------|--------------|---------------|------------------|
| home-assistant | home-automation | Static NFS PV (100Gi) + PostgreSQL | CNPG backups to Garage S3 | **CRITICAL** |
| esphome | home-automation | Longhorn PVC (100Mi) | VolSync to Minio (6-hour) | High |
| zwave | home-automation | Static NFS PV (10Gi) | None | Medium |
| mqtt | home-automation | Longhorn PVC (100Mi) | VolSync to Minio (hourly!) | High |
| archivebox | media | Longhorn PVC (2Gi) | VolSync to Minio (6-hour) | Medium |
| kanboard | self-hosted | Longhorn PVC (200Mi) | VolSync to Minio (6-hour) | Medium |

**Important Discovery**: VolSync apps backup to **Minio** at `s3.internal`, NOT Garage. Future migration to Garage planned separately.

### VolSync Replication Status (Verified 2025-12-26)

```
NAMESPACE         NAME         LAST SYNC              NEXT SYNC             SCHEDULE
home-automation   esphome      2025-12-26T12:02:34Z   2025-12-26T18:00:00Z  0 */6 * * *
home-automation   mqtt         2025-12-26T13:02:28Z   2025-12-26T14:00:00Z  0 * * * *
media             archivebox   2025-12-26T12:02:37Z   2025-12-26T18:00:00Z  0 */6 * * *
self-hosted       kanboard     2025-12-26T12:02:36Z   2025-12-26T18:00:00Z  0 */6 * * *
```

All VolSync backups are current and healthy ✅

### PostgreSQL Databases (CNPG)

| Database | Namespace | Instances | Status | Backup Status |
|----------|-----------|-----------|--------|---------------|
| hass-16-db | home-automation | 3 | Healthy | Daily to Garage S3 (last: 13h ago) |
| mealie-16-db | self-hosted | 3 | Healthy | ArgoCD-managed |
| miniflux-16-db | self-hosted | 3 | Healthy | ArgoCD-managed |
| wallabag-16-db | self-hosted | 3 | Healthy | ArgoCD-managed |
| wikijs-16-db | self-hosted | 3 | Healthy | ArgoCD-managed |

**Note**: mealie, miniflux, wallabag, wikijs are already fully managed by ArgoCD (databases and apps).

## Migration Strategy

### Guiding Principles

1. **Data Safety First**: Verify backups before any migration step
2. **No Downtime for Critical Apps**: home-assistant stays up during migration
3. **Rollback Plan**: Every step must be reversible
4. **Progressive Migration**: One app at a time, validate before proceeding
5. **VolSync Continuity**: Preserve existing backup history where possible

### Pre-Migration Checklist

- [x] Verify all VolSync backups are current (< 6 hours old)
- [x] Verify CNPG backup for home-assistant database
- [x] Create manual snapshots for all VolSync PVCs
- [x] Trigger fresh VolSync syncs
- [x] Audit current SOPS secrets
- [x] Create Bitwarden item for VolSync credentials
- [x] Create CA ConfigMaps for all VolSync apps
- [ ] Create ArgoCD Application manifests for all 6 apps
- [ ] Test kanboard migration (first test case)

## Phase 1: Preparation (Data Safety) ✅ COMPLETE

### 1.1 Backup Verification ✅

**Status**: Complete - All backups verified healthy

**VolSync Backups**:
- ✅ esphome: Last sync 2025-12-26T12:02:34Z (6-hour schedule)
- ✅ mqtt: Last sync 2025-12-26T13:02:28Z (hourly schedule)
- ✅ archivebox: Last sync 2025-12-26T12:02:37Z (6-hour schedule)
- ✅ kanboard: Last sync 2025-12-26T12:02:36Z (6-hour schedule)

**CNPG Backups**:
- ✅ hass-16-db: Last backup 13 hours ago, daily schedule active
- ✅ Scheduled backup resource exists and healthy

### 1.2 Manual Snapshots Created ✅

**Status**: Complete - All snapshots ready

Created Longhorn volume snapshots as safety net:
- ✅ `esphome-pre-argocd-migration` (home-automation, 100Mi)
- ✅ `mqtt-pre-argocd-migration` (home-automation, 100Mi)
- ✅ `archivebox-pre-argocd-migration` (media, 2Gi)
- ✅ `kanboard-pre-argocd-migration` (self-hosted, 200Mi)

**Retention**: Keep for 1 week post-migration, delete after stability confirmed

### 1.3 Fresh VolSync Syncs Triggered ✅

**Status**: Complete

Triggered immediate syncs for all apps to get freshest possible backups before migration:
```bash
kubectl annotate replicationsource -n home-automation esphome volsync.backube/trigger-sync="$(date +%s)" --overwrite
kubectl annotate replicationsource -n home-automation mqtt volsync.backube/trigger-sync="$(date +%s)" --overwrite
kubectl annotate replicationsource -n media archivebox volsync.backube/trigger-sync="$(date +%s)" --overwrite
kubectl annotate replicationsource -n self-hosted kanboard volsync.backube/trigger-sync="$(date +%s)" --overwrite
```

### 1.4 Secret Migration to Bitwarden ✅

**Status**: Complete

**Discovery**: All 4 VolSync apps share the same Minio S3 credentials!

**Shared Credentials**:
- S3 Endpoint: `s3.internal` (Minio, NOT Garage)
- AWS Access Key ID: `BziXxDiyknGH8cEbZdwq`
- AWS Secret Access Key: (same for all)
- Restic Password: `il-etait-une-fois-une-machande-de-foie-qui-ne-vendait-pas-du-foie`
- CA Certificate: Ptinem Root CA (valid until 2034-02-06)

**Unique Per App**:
- RESTIC_REPOSITORY: `s3:https://s3.internal/volsync-volumes/{app-name}`

**Bitwarden Setup** ✅:
- Item Name: `Volsync Minio`
- UUID: `4c7bab21-8e2d-49ee-9762-4d27130790c9`
- Fields:
  - `AWS_ACCESS_KEY_ID` (text)
  - `AWS_SECRET_ACCESS_KEY` (password)
  - `RESTIC_PASSWORD` (password)
  - (RESTIC_REPOSITORY will be customized per app in manifests)

### 1.5 CA ConfigMap Creation ✅

**Status**: Complete

Created CA ConfigMaps for Minio TLS verification (Ptinem Root CA):
- ✅ `kubernetes/base/apps/home-automation/esphome/volsync-ca-configmap.yaml`
- ✅ `kubernetes/base/apps/home-automation/mqtt/volsync-ca-configmap.yaml`
- ✅ `kubernetes/base/apps/media/archivebox/volsync-ca-configmap.yaml`
- ✅ `kubernetes/base/apps/self-hosted/kanboard/volsync-ca-configmap.yaml`

### 1.6 App Directory Structure Created ✅

**Status**: Complete

Created ArgoCD app directories:
- ✅ `kubernetes/base/apps/home-automation/esphome/`
- ✅ `kubernetes/base/apps/home-automation/mqtt/`
- ✅ `kubernetes/base/apps/media/archivebox/`
- ✅ `kubernetes/base/apps/self-hosted/kanboard/`

## Phase 2: Low-Risk Migrations (Non-Critical Apps)

**Status**: Ready to begin

**Target Apps**: kanboard (VolSync test case), zwave (no backup)

### 2.1 Migrate kanboard

**Risk**: Low (VolSync backup, low usage, good test case)

**Pre-flight Checks**:
- [x] VolSync backup current (last sync today)
- [x] Manual snapshot created
- [ ] ExternalSecret manifest created
- [ ] ReplicationSource/Destination manifests created
- [ ] ArgoCD Application created

**Steps**:

1. **Create ArgoCD manifests**:
   - Copy deployment, service, ingress, config from Flux
   - Create ExternalSecret pointing to Bitwarden UUID `4c7bab21-8e2d-49ee-9762-4d27130790c9`
   - Create ReplicationSource with schedule `0 */6 * * *` (6-hour)
   - Create ReplicationDestination for bootstrap
   - Create kustomization.yaml

2. **Create ArgoCD Application**:
   ```yaml
   # kubernetes/base/apps/self-hosted/kanboard-app.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: kanboard
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://forge.internal/ndufour/avalanche.git
       targetRevision: main
       path: kubernetes/base/apps/self-hosted/kanboard
     destination:
       server: https://kubernetes.default.svc
       namespace: self-hosted
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

3. **Apply ArgoCD Application**:
   ```bash
   kubectl apply -f kubernetes/base/apps/self-hosted/kanboard-app.yaml
   ```

4. **Monitor ArgoCD sync and VolSync**:
   ```bash
   argocd app get kanboard
   kubectl get replicationsource -n self-hosted kanboard -w
   ```

5. **Verify backup continuity** (wait 6 hours for next scheduled backup)

6. **Suspend Flux Kustomization** (after 24-48 hours of stability):
   ```bash
   flux suspend kustomization self-hosted-kanboard
   ```

7. **Delete Flux Kustomization** (after 1 week):
   ```bash
   flux delete kustomization self-hosted-kanboard --silent
   ```

**Success Criteria**:
- ArgoCD app shows "Synced" and "Healthy"
- Pod is running
- VolSync continues 6-hour backups
- Web UI accessible
- Stable for 24-48 hours

**Rollback**: If fails, delete ArgoCD app (--cascade=false), resume Flux kustomization

### 2.2 Migrate zwave

**Risk**: Medium (static PV, no backup, low usage)

**Pre-flight**:
- [ ] Document static PV binding (zwave-pv → zwave-pvc)
- [ ] Copy deployment manifests

**Steps**:

1. **Copy Flux manifests to ArgoCD structure**:
   ```bash
   mkdir -p kubernetes/base/apps/home-automation/zwave
   cp kubernetes/kubernetes/main/apps/home-automation/zwave/app/* \
      kubernetes/base/apps/home-automation/zwave/
   ```

2. **Verify PV/PVC configuration** (static NFS binding):
   - Ensure PV `claimRef` matches namespace
   - Keep `persistentVolumeReclaimPolicy: Retain`

3. **Create ArgoCD Application**:
   ```bash
   kubectl apply -f kubernetes/base/apps/home-automation/zwave-app.yaml
   ```

4. **Verify Z-Wave devices still work**

5. **Suspend/Delete Flux** after 48 hours

**Success Criteria**:
- Pod running
- Z-Wave devices responsive
- Stable for 48 hours

## Phase 3: VolSync Apps Migration

**Status**: Pending Phase 2 completion

**Target Apps**: mqtt, esphome, archivebox

### 3.1 Migrate mqtt

**Risk**: Medium-High (hourly backups indicate importance)

**Configuration**:
- Schedule: `0 * * * *` (hourly!)
- Storage: 100Mi
- Cache: 100Mi (or 2Gi based on existing volsync-src-mqtt-cache)

**Steps**: Same pattern as kanboard, but verify hourly backup schedule preserved

**Success Criteria**:
- Hourly backups continue (verify for 24 hours)
- MQTT clients remain connected
- No message loss

### 3.2 Migrate esphome

**Risk**: Medium (6-hour VolSync backups)

**Configuration**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 100Mi
- Cache: 100Mi

**Steps**: Same pattern as kanboard

**Success Criteria**:
- ESPHome devices reachable
- Firmware uploads work
- 6-hour backups continue

### 3.3 Migrate archivebox

**Risk**: Low-Medium (6-hour VolSync backups, low usage)

**Configuration**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 2Gi
- Cache: 2Gi

**Steps**: Same pattern as kanboard

**Success Criteria**:
- Web UI accessible
- Archive downloads work
- 6-hour backups continue

## Phase 4: Critical App Migration (home-assistant)

**Status**: Pending Phase 3 completion

**Risk**: **CRITICAL** - Most complex migration

### Pre-Migration Safety Net

1. **Full CNPG database backup**:
   ```bash
   # Trigger immediate backup
   kubectl annotate cluster -n home-automation hass-16-db \
     cnpg.io/immediateBackup="$(date +%s)"

   # Verify backup completed
   kubectl get cluster -n home-automation hass-16-db -o yaml | grep lastSuccessfulBackup
   ```

2. **Document current state**:
   ```bash
   kubectl get all -n home-automation -l app=home-assistant -o yaml > ha-pre-migration.yaml
   kubectl get pvc,pv -n home-automation -l app=home-assistant -o yaml >> ha-pre-migration.yaml
   ```

3. **NFS PV backup** (manual, outside cluster):
   - Backup NFS mount point on storage host
   - Or use storage system snapshot if available

### Migration Steps

1. **Copy manifests to ArgoCD structure**:
   ```bash
   mkdir -p kubernetes/base/apps/home-automation/home-assistant
   cp -r kubernetes/kubernetes/main/apps/home-automation/home-assistant/app/* \
      kubernetes/base/apps/home-automation/home-assistant/
   ```

2. **Convert SOPS secrets to ExternalSecrets**:
   - Create Bitwarden item for Home Assistant (separate from VolSync)
   - Test secret retrieval before proceeding

3. **Preserve PostgreSQL cluster** (CRITICAL):
   - **DO NOT RECREATE** the CNPG Cluster resource
   - ArgoCD must adopt existing cluster
   - Add annotation to existing cluster:
     ```bash
     kubectl annotate cluster -n home-automation hass-16-db \
       argocd.argoproj.io/tracking-id="home-assistant:postgresql.cnpg.io/Cluster:home-automation/hass-16-db"
     ```

4. **Apply ArgoCD Application** (DRY RUN first):
   ```bash
   kubectl apply -f kubernetes/base/apps/home-automation/home-assistant-app.yaml --dry-run=server
   ```

5. **Monitor sync closely**:
   ```bash
   argocd app get home-assistant --refresh
   kubectl get pods -n home-automation -l app=home-assistant -w
   ```

6. **Verify functionality**:
   - Web UI access
   - All integrations working
   - Database connectivity
   - Automation triggers

7. **Soak for 1 WEEK** before disabling Flux

8. **Suspend Flux Kustomization**:
   ```bash
   flux suspend kustomization cluster-apps-ha-home-assistant
   ```

9. **Final verification** (another 48 hours)

10. **Delete Flux Kustomization**:
    ```bash
    flux delete kustomization cluster-apps-ha-home-assistant --silent
    ```

### Rollback Procedure

If anything goes wrong:

1. **Immediate**:
   ```bash
   argocd app delete home-assistant --cascade=false  # Keep resources
   flux resume kustomization cluster-apps-ha-home-assistant
   ```

2. **If database corrupted**:
   - Restore from CNPG backup:
     ```bash
     kubectl cnpg backup hass-16-db --recovery-target-time="<timestamp>"
     ```

3. **If PV data corrupted**:
   - Restore from NFS backup (manual)

**Success Criteria**:
- ArgoCD app "Synced" and "Healthy"
- All Home Assistant features working
- CNPG database healthy
- Stable for 1+ week

## Phase 5: Flux Cleanup

**Status**: Pending Phase 4 completion

**Only after all apps successfully migrated and stable for 1+ week**

### 5.1 Verify No Active Flux Apps

```bash
flux get kustomizations -A

# Should only show:
# - flux-system/flux (Flux itself)
# - flux-system/flux-addons
# - flux-system/cluster (parent)
# - flux-system/apps (parent)
```

### 5.2 Delete Flux Parent Kustomizations

```bash
flux suspend kustomization apps
flux suspend kustomization cluster
flux delete kustomization apps --silent
flux delete kustomization cluster --silent
```

### 5.3 (Optional) Remove Flux Entirely

**Recommendation**: Keep Flux dormant for 1 month for easier rollback

```bash
# Later, if desired:
flux uninstall --namespace=flux-system --silent
```

### 5.4 Archive Flux Manifests

```bash
mkdir -p kubernetes/archive/flux-legacy
mv kubernetes/kubernetes/main/ kubernetes/archive/flux-legacy/
git add kubernetes/archive/
git commit -m "Archive Flux manifests after migration to ArgoCD"
```

### 5.5 Delete Manual Snapshots

After 1 week of stability:
```bash
kubectl delete volumesnapshot -n home-automation esphome-pre-argocd-migration
kubectl delete volumesnapshot -n home-automation mqtt-pre-argocd-migration
kubectl delete volumesnapshot -n media archivebox-pre-argocd-migration
kubectl delete volumesnapshot -n self-hosted kanboard-pre-argocd-migration
```

## Phase 6: Documentation Update

**Status**: Pending Phase 5 completion

1. **Update main README.md**:
   - Remove Flux references
   - Update GitOps section to "ArgoCD only"
   - Update `just k8s-bootstrap` docs

2. **Update CLAUDE.md**:
   - Remove "Flux (legacy/transitioning)" notes
   - Update GitOps architecture section
   - Update troubleshooting guides

3. **Create migration completion document**:
   - `docs/migration/flux-to-argocd-completion.md`
   - Lessons learned
   - Issues encountered and resolutions

4. **Update volsync-minio-to-garage migration plan** (future):
   - Document migration from Minio to Garage for VolSync
   - Separate effort, lower priority

## Rollback Procedures

### Per-App Rollback

If an app fails after ArgoCD migration:

1. Delete ArgoCD Application (keep resources):
   ```bash
   argocd app delete <app-name> --cascade=false
   ```

2. Resume Flux Kustomization:
   ```bash
   flux resume kustomization <kustomization-name>
   ```

3. Force Flux reconciliation:
   ```bash
   flux reconcile kustomization <kustomization-name> --with-source
   ```

### Full Rollback

If multiple apps fail or systemic issues:

1. Resume all Flux Kustomizations:
   ```bash
   flux resume kustomization --all
   ```

2. Delete all ArgoCD Applications for migrated apps:
   ```bash
   argocd app delete esphome zwave mqtt archivebox kanboard home-assistant --cascade=false
   ```

3. Investigate root cause before retrying

## Success Criteria

### Per-App Success

- [ ] ArgoCD Application shows "Synced" and "Healthy"
- [ ] App pods running and healthy
- [ ] App functionality verified (web UI, integrations, etc.)
- [ ] VolSync backups continuing (if applicable)
- [ ] CNPG backups continuing (if applicable)
- [ ] No errors in app logs
- [ ] Stable for 24-48 hours minimum

### Overall Migration Success

- [ ] All 6 Flux apps migrated to ArgoCD
- [ ] All apps stable for 1+ week
- [ ] All VolSync backups healthy and current
- [ ] All CNPG databases healthy with recent backups
- [ ] Flux parent Kustomizations removed
- [ ] Documentation updated
- [ ] Manual snapshots deleted

## Timeline Estimate

| Phase | Duration | Cumulative | Status |
|-------|----------|------------|--------|
| Phase 1: Preparation | 1-2 days | 2 days | ✅ COMPLETE |
| Phase 2: Low-risk (zwave, kanboard) | 2-3 days | 5 days | 🔜 NEXT |
| Phase 3: VolSync apps (mqtt, esphome, archivebox) | 3-5 days | 10 days | ⏳ Pending |
| Phase 4: home-assistant | 7-10 days (1 week soak) | 20 days | ⏳ Pending |
| Phase 5: Flux cleanup | 1 day | 21 days | ⏳ Pending |
| Phase 6: Documentation | 1 day | 22 days | ⏳ Pending |

**Total: ~3-4 weeks** (including soak times and contingency)

## Risk Matrix

| App | Data Criticality | Complexity | Migration Risk | Soak Time | Status |
|-----|------------------|------------|----------------|-----------|--------|
| kanboard | Low | Medium (VolSync) | Low | 48 hours | 🔜 NEXT |
| zwave | Medium | Low | Medium | 48 hours | 🔜 NEXT |
| mqtt | High | Medium (VolSync hourly) | Medium-High | 72 hours | ⏳ Pending |
| esphome | Medium | Medium (VolSync) | Medium | 48 hours | ⏳ Pending |
| archivebox | Low | Medium (VolSync) | Low | 48 hours | ⏳ Pending |
| home-assistant | **CRITICAL** | **Very High** (DB + PV) | **HIGH** | **1 week** | ⏳ Pending |

## Key Configurations Discovered

### VolSync Minio Setup

**S3 Endpoint**: `s3.internal` (Minio)
**Repository Pattern**: `s3:https://s3.internal/volsync-volumes/{app-name}`

**Shared Credentials** (Bitwarden: `4c7bab21-8e2d-49ee-9762-4d27130790c9`):
- AWS_ACCESS_KEY_ID: `BziXxDiyknGH8cEbZdwq`
- AWS_SECRET_ACCESS_KEY: (stored in Bitwarden)
- RESTIC_PASSWORD: `il-etait-une-fois-une-machande-de-foie-qui-ne-vendait-pas-du-foie`

**CA Certificate** (Ptinem Root CA):
- Valid until: 2034-02-06
- Stored in ConfigMaps (public cert, not secret)

### VolSync Configurations by App

**kanboard**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 200Mi (Longhorn RWX)
- Cache: 200Mi (for ReplicationDestination)
- User/Group: 100:101
- Retention: 24 hourly, 7 daily, 5 weekly

**mqtt**:
- Schedule: `0 * * * *` (hourly!)
- Storage: 100Mi (Longhorn RWO)
- Cache: 2Gi (existing volsync-src-mqtt-cache)
- User/Group: TBD (check Flux config)

**esphome**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 100Mi (Longhorn RWX)
- Cache: 100Mi
- User/Group: TBD (check Flux config)
- Retention: 24 hourly, 7 daily, 5 weekly

**archivebox**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 2Gi (Longhorn RWX)
- Cache: 2Gi
- User/Group: TBD (check Flux config)

## Monitoring and Alerts

### During Migration

**Watch**:
- ArgoCD sync status: `argocd app list`
- VolSync replication: `kubectl get replicationsources -A`
- CNPG clusters: `kubectl get clusters -A`
- Pod health: `kubectl get pods -A | grep -E "(esphome|mqtt|archivebox|kanboard|home-assistant|zwave)"`

**Manual Checks**:
- VolSync backup age (< 6 hours for most, < 1 hour for mqtt)
- CNPG backup age (< 24 hours)
- Pod CrashLoopBackOff
- Service availability

### Post-Migration

**Daily (first week)**:
- ArgoCD app health
- VolSync backup age
- CNPG backup age

**Weekly (ongoing)**:
- Review ArgoCD app sync history
- Verify backup retention policies working

## Questions to Answer Before Continuing

1. ✅ Bitwarden access: Bitwarden item created with UUID
2. ❓ VolSync component vs custom manifests: Which approach to use?
3. ❓ Static PV migration: For zwave/home-assistant, keep NFS PVs or migrate to Longhorn?
4. ❓ Maintenance window: Do we need scheduled downtime for home-assistant migration?
5. ❓ Monitoring: Set up automated alerts for VolSync/CNPG backup failures?

## Next Steps

1. ✅ Phase 1 complete
2. 🔜 Create ArgoCD manifests for kanboard (test case)
3. 🔜 Test kanboard migration
4. ⏳ Create manifests for remaining apps
5. ⏳ Execute migrations per phase
6. ⏳ Document deviations/issues

---

**Author**: Claude Code
**Last Updated**: 2025-12-26
**Status**: ✅ Phase 1 Complete - Ready for Phase 2
