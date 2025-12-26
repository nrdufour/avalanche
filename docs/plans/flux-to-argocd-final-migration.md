# Flux to ArgoCD Final Migration Plan

**Created**: 2025-12-26
**Last Updated**: 2025-12-26 (5 of 6 apps migrated - only home-assistant remaining)
**Status**: ✅ Phase 3 Complete - Ready for home-assistant (final app)
**Priority**: High - Complete GitOps consolidation

## Executive Summary

This plan outlines the final migration of 6 Flux-managed applications to ArgoCD, with critical focus on data safety for apps using VolSync backups and PostgreSQL databases.

**Progress**:
- ✅ Phase 1 (Preparation) complete - All backups verified, manual snapshots created, secrets migrated to Bitwarden
- ✅ Phase 2 (Low-Risk Apps) complete - kanboard and zwave migrated successfully
- ✅ Phase 3 (VolSync Apps) complete - mqtt, esphome, archivebox all migrated with zero downtime
- 🔜 Phase 4 (Critical App) - home-assistant remaining (PostgreSQL + static NFS PV)

**Key Achievement**: All 5 apps migrated with ZERO downtime - pods never restarted, VolSync backups working perfectly across all apps.

## Current State (from cluster inspection - 2025-12-26)

### Application Migration Status (6 total)

| App | Namespace | Storage Type | Backup Method | Data Criticality | Status |
|-----|-----------|--------------|---------------|------------------|--------|
| kanboard | self-hosted | Longhorn PVC (200Mi) | VolSync to Minio (6-hour) | Medium | ✅ Migrated |
| zwave | home-automation | Static NFS PV (10Gi) | None | Medium | ✅ Migrated |
| mqtt | home-automation | Longhorn PVC (100Mi) | VolSync to Minio (hourly!) | High | ✅ Migrated |
| esphome | home-automation | Longhorn PVC (100Mi) | VolSync to Minio (6-hour) | High | ✅ Migrated |
| archivebox | media | Longhorn PVC (2Gi) | VolSync to Minio (6-hour) | Medium | ✅ Migrated |
| home-assistant | home-automation | Static NFS PV (100Gi) + PostgreSQL | CNPG backups to Garage S3 | **CRITICAL** | 🔜 Pending |

**Important Discovery**: VolSync apps backup to **Minio** at `s3.internal`, NOT Garage. Future migration to Garage planned separately.

### VolSync Replication Status (Post-Migration - 2025-12-26)

All apps migrated to ArgoCD and VolSync backups verified working:

```
NAMESPACE         NAME         LAST SYNC              NEXT SYNC             SCHEDULE      STATUS
home-automation   mqtt         2025-12-26T15:08:44Z   2025-12-26T16:00:00Z  0 * * * *     ✅ Migrated
home-automation   esphome      2025-12-26T15:08:46Z   2025-12-26T18:00:00Z  0 */6 * * *    ✅ Migrated
media             archivebox   2025-12-26T15:44:49Z   2025-12-26T18:00:00Z  0 */6 * * *    ✅ Migrated
self-hosted       kanboard     2025-12-26T12:38:11Z   2025-12-26T18:00:00Z  0 */6 * * *    ✅ Migrated
```

All VolSync backups current, healthy, and managed by ArgoCD ✅

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

### Proven Migration Approach (Adopt-in-Place)

**Successfully tested with kanboard migration (2025-12-26)**

The "adopt-in-place" strategy ensures zero downtime and prevents resource conflicts between Flux and ArgoCD:

**Critical Rule**: Resources must be orphaned BEFORE ArgoCD becomes aware of them. Never have both Flux and ArgoCD managing the same resources simultaneously - they will fight forever.

**Steps**:

1. **Set prune: false in Flux Kustomization** (in git, not kubectl):
   - Edit `kubernetes/kubernetes/main/apps/<namespace>/<app>/ks.yaml`
   - Change `spec.prune: true` to `spec.prune: false`
   - Commit and push to git
   - Wait for Flux to reconcile (resources are now "sticky")

2. **Orphan resources by removing Flux reference**:
   - Edit parent `kustomization.yaml` that references the app
   - Comment out (don't delete) the `- ./<app>/ks.yaml` reference
   - Commit and push
   - Verify resources are no longer managed: `kubectl get <resource> -o yaml | grep manager` (should show empty or no manager)

3. **Prepare ArgoCD manifests** (in `kubernetes/base/apps/<category>/<app>/`):
   - Copy manifests from Flux structure
   - Replace SOPS secrets with ExternalSecrets (Bitwarden)
   - Fix any configuration issues (e.g., VolSync CA should use configMapName, not secretName)
   - Create kustomization.yaml
   - Create ArgoCD Application manifest

4. **Apply ArgoCD Application**:
   - Add app to parent kustomization (e.g., `kubernetes/base/apps/<category>/kustomization.yaml`)
   - Commit and push
   - ArgoCD auto-syncs and adopts orphaned resources
   - Verify: `argocd app get <app>` shows "Synced" and "Healthy"

5. **Verify functionality**:
   - Pods still running (zero downtime)
   - VolSync backups working (trigger manual sync to test)
   - Application accessible and functional

6. **Clean up manual trigger** (IMPORTANT):
   ```bash
   # After testing manual sync, restore scheduled syncs
   kubectl patch replicationsource -n <namespace> <name> --type=json \
     -p='[{"op": "remove", "path": "/spec/trigger/manual"}]'
   ```
   **Why**: Manual trigger takes precedence over schedule. Must be removed to restore scheduled syncs.

7. **Verify scheduled syncs restored**:
   ```bash
   kubectl get replicationsources -A  # Should show NEXT SYNC time
   ```

8. **Soak period** (optional, 48 hours to 1 week depending on criticality)

**Why this works**:
- Resources are created and running BEFORE the migration
- Setting prune: false ensures Flux won't delete them when we remove its reference
- Orphaning resources removes Flux ownership without destroying the resources
- ArgoCD adopts existing resources that match its manifests (no recreation)
- Zero downtime achieved because resources never get deleted/recreated

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

## Phase 2: Low-Risk Migrations (Non-Critical Apps) ✅ COMPLETE

**Status**: ✅ Both apps migrated successfully with zero downtime

**Target Apps**: kanboard (VolSync test case), zwave (Helm chart with static NFS PV)

### 2.1 Migrate kanboard ✅ COMPLETE

**Risk**: Low (VolSync backup, low usage, good test case)

**Migration Date**: 2025-12-26

**Pre-flight Checks**:
- [x] VolSync backup current (last sync today)
- [x] Manual snapshot created
- [x] ExternalSecret manifest created
- [x] ReplicationSource/Destination manifests created
- [x] ArgoCD Application created

**Steps Executed** (using adopt-in-place approach):

1. **Set prune: false in Flux**:
   - ✅ Edited `kubernetes/kubernetes/main/apps/self-hosted/kanboard/ks.yaml`
   - ✅ Changed `spec.prune: true` to `spec.prune: false`
   - ✅ Committed and pushed to git
   - ✅ Flux reconciled the change

2. **Orphaned resources**:
   - ✅ Commented out kanboard reference in `kubernetes/kubernetes/main/apps/self-hosted/kustomization.yaml`
   - ✅ Resources became orphaned (no manager)

3. **Created ArgoCD manifests** in `kubernetes/base/apps/self-hosted/kanboard/`:
   - ✅ Copied deployment, service, ingress, config from Flux
   - ✅ Created ExternalSecret pointing to Bitwarden UUID `4c7bab21-8e2d-49ee-9762-4d27130790c9`
   - ✅ Created ReplicationSource with schedule `0 */6 * * *` (6-hour)
   - ✅ Created ReplicationDestination for bootstrap
   - ✅ Created kustomization.yaml
   - ✅ Fixed CA certificate reference (configMapName instead of secretName)

4. **Applied ArgoCD Application**:
   - ✅ Created `kubernetes/base/apps/self-hosted/kanboard-app.yaml`
   - ✅ Added to `kubernetes/base/apps/self-hosted/kustomization.yaml`
   - ✅ ArgoCD auto-synced and adopted resources

5. **Verified migration success**:
   - ✅ ArgoCD app status: "Synced" and "Healthy"
   - ✅ Pod still running (zero downtime achieved)
   - ✅ VolSync manual sync triggered and completed successfully
   - ✅ Snapshot 0bcfa8e9 created (11.602 MiB, 281 files)
   - ✅ Web UI accessible

6. **Cleaned up manual trigger**:
   - ✅ Removed manual trigger to restore scheduled syncs
   - ✅ Verified next scheduled sync: 2025-12-26T18:00:00Z

**Issues Fixed**:
- ExternalSecret API version: Changed from `v1beta1` to `v1`
- VolSync CA certificate: Changed from `secretName: kanboard-volsync-minio` to `configMapName: kanboard-volsync-ca`
- Manual trigger cleanup: Removed manual trigger to restore scheduled syncs

**Success Criteria**: ✅ ALL MET
- ✅ ArgoCD app shows "Synced" and "Healthy"
- ✅ Pod is running (4+ days old, zero downtime)
- ✅ VolSync manual sync completed successfully
- ✅ Scheduled syncs restored (next: 18:00:00Z)
- ✅ Web UI accessible

**Next Steps**:
- Ready to proceed with next app migration
- Delete Flux Kustomization file after all apps migrated
- Delete manual snapshot after 1 week

**Lessons Learned** (kanboard-specific):
1. Adopt-in-place strategy works perfectly for zero-downtime migrations
2. ExternalSecrets operator uses v1 API (not v1beta1)
3. VolSync CA certs should reference ConfigMaps (not Secrets) via configMapName
4. Manual triggers must be cleaned up after testing (use `kubectl patch --type=json -p='[{"op": "remove", "path": "/spec/trigger/manual"}]'`)
5. Resources can be safely orphaned and re-adopted without recreation

## Common Issues Encountered Across All Migrations

Through migrating 5 apps, the following issues were encountered and resolved:

### 1. VolSync CA Certificate Configuration ✅ FIXED
**Issue**: ReplicationSource using `secretName` for CA cert when it should use `configMapName`
**Symptom**: `"secret is missing field: ca.crt"`
**Fix**:
```yaml
customCA:
  configMapName: {app}-volsync-ca  # NOT secretName
  key: ca.crt
```
**Apps Affected**: kanboard, esphome, archivebox

### 2. Conflicting secretName Field ✅ FIXED
**Issue**: Flux ReplicationSource had both `secretName` and `configMapName` merged together
**Symptom**: VolSync looking for ca.crt in wrong resource type
**Fix**: Remove secretName via kubectl patch:
```bash
kubectl patch replicationsource -n {namespace} {name} --type=json \
  -p='[{"op": "remove", "path": "/spec/restic/customCA/secretName"}]'
```
**Apps Affected**: esphome, archivebox

### 3. ExternalSecret dataFrom Conflict ✅ FIXED
**Issue**: ExternalSecret with both `data` and `dataFrom` sections
**Symptom**: `"failed to get response (wrong type: []interface {})"`
**Fix**: Remove `dataFrom` section, use only `data` with explicit field mappings
**Apps Affected**: archivebox

### 4. Wrong volumeSnapshotClassName ✅ FIXED
**Issue**: Using `longhorn` instead of `longhorn-snapshot-vsc`
**Symptom**: `"backup target default is not available"` - Longhorn trying to use backup target for snapshots
**Fix**: Change to `longhorn-snapshot-vsc` in ReplicationSource and ReplicationDestination
**Apps Affected**: archivebox

### 5. Missing Parent Kustomization Reference ✅ FIXED (recurring)
**Issue**: Forgetting to commit parent kustomization.yaml that references the ArgoCD Application
**Symptom**: ArgoCD not picking up the new Application
**Fix**: ALWAYS run `git status` before pushing to verify all files committed
**Apps Affected**: zwave, mqtt, esphome (recurring mistake)

### 6. Multiple Sources for Helm + VolSync ✅ FIXED
**Issue**: ArgoCD Application only referencing OCI Helm chart, missing VolSync manifests
**Symptom**: VolSync resources not deployed
**Fix**: Use ArgoCD's multiple sources feature:
```yaml
sources:
  - repoURL: oci://ghcr.io/bjw-s/helm/app-template  # Helm chart
  - repoURL: https://forge.internal/nemo/avalanche.git  # VolSync manifests
    path: kubernetes/base/apps/{category}/{app}
```
**Apps Affected**: esphome

### 7. Stuck VolumeSnapshot from Wrong Class ✅ FIXED
**Issue**: VolumeSnapshot stuck with wrong volumeSnapshotClassName, preventing new syncs
**Symptom**: Snapshot stays in `READYTOUSE: false` state
**Fix**: Force delete by removing finalizer:
```bash
kubectl patch volumesnapshot -n {namespace} {name} -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete volumesnapshot -n {namespace} {name} --wait=false
```
**Apps Affected**: archivebox

### Key Patterns Identified:
1. **Always use `configMapName` for CA certificates** in VolSync (ConfigMaps are for public certs)
2. **Always use `longhorn-snapshot-vsc`** for volumeSnapshotClassName (not bare `longhorn`)
3. **Always check git status** before pushing (recurring mistake with parent kustomizations)
4. **Always clean up manual triggers** after testing to restore scheduled syncs
5. **For Helm + VolSync**: Use multiple sources in ArgoCD Application

### 2.2 Migrate zwave ✅ COMPLETE

**Risk**: Medium (static NFS PV, no backup, low usage)

**Migration Date**: 2025-12-26

**Pre-flight Checks**:
- [x] Documented static PV binding (zwave-pv → zwave-pvc)
- [x] Verified NFS mount: `possum.internal:/tank/NFS/zwave`
- [x] Set prune: false in Flux
- [x] Orphaned resources

**Steps Executed**:

1. **Set prune: false and orphan**:
   - ✅ Edited `kubernetes/kubernetes/main/apps/home-automation/zwave/ks.yaml`
   - ✅ Commented out zwave reference in parent kustomization
   - ✅ Resources orphaned successfully

2. **Created ArgoCD Application** (using OCI Helm chart):
   - ✅ Used `oci://ghcr.io/bjw-s/helm/app-template:3.7.3`
   - ✅ Configured with Helm values inline
   - ✅ Created static NFS PV/PVC manifests
   - ✅ Applied ArgoCD Application

3. **Verified migration success**:
   - ✅ ArgoCD app status: "Synced" and "Healthy"
   - ✅ Pod running (zero downtime)
   - ✅ Static NFS PV bound correctly
   - ✅ Z-Wave devices operational

**Key Configuration**:
- Static NFS PV: 10Gi at `possum.internal:/tank/NFS/zwave`
- PV Policy: `Retain` (data persists if PVC deleted)
- Access Mode: ReadWriteMany

**Success Criteria**: ✅ ALL MET
- ✅ Pod running without restart
- ✅ Static NFS PV working
- ✅ Z-Wave devices responsive

## Phase 3: VolSync Apps Migration ✅ COMPLETE

**Status**: ✅ All 3 apps migrated successfully with zero downtime

**Target Apps**: mqtt, esphome, archivebox

### 3.1 Migrate mqtt ✅ COMPLETE

**Risk**: Medium-High (hourly backups indicate importance)

**Migration Date**: 2025-12-26

**Configuration**:
- Schedule: `0 * * * *` (hourly!)
- Storage: 100Mi Longhorn PVC
- Cache: 2Gi
- User/Group: 1883:1883

**Steps Executed**:
1. ✅ Set prune: false and orphaned resources
2. ✅ Created ArgoCD manifests (deployment, service, PVC, config)
3. ✅ Created VolSync ExternalSecret (Bitwarden UUID: `4c7bab21-8e2d-49ee-9762-4d27130790c9`)
4. ✅ Created ReplicationSource/Destination with CA ConfigMap
5. ✅ Applied ArgoCD Application
6. ✅ Triggered manual VolSync sync - SUCCESS
7. ✅ Cleaned up manual trigger to restore hourly schedule

**Success Criteria**: ✅ ALL MET
- ✅ Pod running without restart (4d6h uptime)
- ✅ VolSync manual sync successful
- ✅ Hourly schedule restored (next sync at top of hour)
- ✅ MQTT clients remain connected

### 3.2 Migrate esphome ✅ COMPLETE

**Risk**: Medium (6-hour VolSync backups)

**Migration Date**: 2025-12-26

**Configuration**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 100Mi Longhorn PVC
- Cache: 100Mi
- User/Group: 568:568

**Steps Executed**:
1. ✅ Set prune: false and orphaned resources
2. ✅ Created ArgoCD Application using **multiple sources**:
   - Source 1: OCI Helm chart (`oci://ghcr.io/bjw-s/helm/app-template:3.7.3`)
   - Source 2: Local git directory for VolSync manifests
3. ✅ Created VolSync manifests with CA ConfigMap
4. ✅ Fixed VolSync CA certificate issue (removed conflicting secretName)
5. ✅ Triggered manual sync - SUCCESS
6. ✅ Cleaned up manual trigger

**Issues Fixed**:
- Missing VolSync manifests in initial ArgoCD app (added multiple sources)
- Conflicting secretName field in customCA (removed via kubectl patch)

**Success Criteria**: ✅ ALL MET
- ✅ Pod running without restart
- ✅ VolSync manual sync successful
- ✅ 6-hour schedule restored
- ✅ ESPHome devices reachable

**Key Learning**: For Helm charts with additional manifests (VolSync), use ArgoCD's multiple sources feature.

### 3.3 Migrate archivebox ✅ COMPLETE

**Risk**: Low-Medium (6-hour VolSync backups, low usage)

**Migration Date**: 2025-12-26

**Configuration**:
- Schedule: `0 */6 * * *` (6-hour)
- Storage: 2Gi Longhorn PVC (RWX)
- Cache: 2Gi
- User/Group: 1000:1000
- Node Selector: `opi.feature.node.kubernetes.io/5plus=true`

**Steps Executed**:
1. ✅ Set prune: false and orphaned resources
2. ✅ Created ArgoCD manifests (deployment with init container, service, ingress, PVC)
3. ✅ Created VolSync manifests with CA ConfigMap
4. ✅ Fixed ExternalSecret (removed dataFrom conflict, hardcoded RESTIC_REPOSITORY)
5. ✅ Fixed volumeSnapshotClassName (`longhorn` → `longhorn-snapshot-vsc`)
6. ✅ Fixed VolSync CA certificate issue (removed conflicting secretName)
7. ✅ Triggered manual sync - SUCCESS (snapshot d45c719b saved)
8. ✅ Cleaned up manual trigger

**Issues Fixed**:
- Component path incorrect (wrong number of `../` levels)
- ExternalSecret had conflicting `dataFrom` section
- Wrong volumeSnapshotClassName caused Longhorn backup target error
- Conflicting secretName in customCA

**Success Criteria**: ✅ ALL MET
- ✅ Pod running without restart (4d6h uptime)
- ✅ VolSync manual sync successful (snapshot d45c719b)
- ✅ 6-hour schedule restored
- ✅ Web UI accessible at archivebox.internal

**Key Configuration**:
- Init container runs `archivebox init` before main container starts
- Node selector ensures deployment to Orange Pi 5 Plus nodes only

## Phase 4: Critical App Migration (home-assistant)

**Status**: 🔜 Ready to begin (Phase 3 complete)

**Risk**: **CRITICAL** - Most complex migration (PostgreSQL + static NFS PV)

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
| Phase 1: Preparation | 1-2 days | 2 days | ✅ COMPLETE (2025-12-26) |
| Phase 2.1: kanboard | 1 day | 3 days | ✅ COMPLETE (2025-12-26) |
| Phase 2.2: zwave | 1 day | 4 days | ✅ COMPLETE (2025-12-26) |
| Phase 3: VolSync apps (mqtt, esphome, archivebox) | 1 day | 5 days | ✅ COMPLETE (2025-12-26) |
| Phase 4: home-assistant | 7-10 days (1 week soak) | 15 days | 🔜 READY TO BEGIN |
| Phase 5: Flux cleanup | 1 day | 16 days | ⏳ Pending Phase 4 |
| Phase 6: Documentation | 1 day | 17 days | ⏳ Pending Phase 5 |

**Progress**: 5 of 6 apps migrated in **1 day** (2025-12-26) - faster than estimated!
**Remaining**: home-assistant (most critical, needs careful planning)

## Risk Matrix

| App | Data Criticality | Complexity | Migration Risk | Soak Time | Status |
|-----|------------------|------------|----------------|-----------|--------|
| kanboard | Low | Medium (VolSync) | Low | 48 hours | ✅ COMPLETE |
| zwave | Medium | Low (OCI Helm) | Medium | 48 hours | ✅ COMPLETE |
| mqtt | High | Medium (VolSync hourly) | Medium-High | 72 hours | ✅ COMPLETE |
| esphome | Medium | Medium (Helm + VolSync) | Medium | 48 hours | ✅ COMPLETE |
| archivebox | Low | Medium (VolSync) | Low | 48 hours | ✅ COMPLETE |
| home-assistant | **CRITICAL** | **Very High** (DB + PV) | **HIGH** | **1 week** | 🔜 READY |

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
**Last Updated**: 2025-12-26 (Post-Phase 3)
**Status**: ✅ 5 of 6 apps migrated - Ready for home-assistant (final app)
