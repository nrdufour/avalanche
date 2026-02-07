# CloudNative-PG Backup Migration: Minio to Garage

**Status**: Complete — 7/7 clusters migrated
**Created**: 2026-01-11
**Updated**: 2026-02-07
**Migration Strategy**: Per-cluster, starting with low-activity clusters

## Executive Summary

Migrate all CloudNative-PG (CNPG) cluster backups from Minio S3 (`s3.internal`) to Garage S3 (`s3.garage.internal`). WAL archiving is kept enabled — it is **required** for backup recovery (see [Lesson 6](#6-wal-archiving-cannot-be-disabled)).

**Critical Constraint**: This is production database backup data. Data loss is unacceptable.

**Migration Strategy**: "Backup, Sync, Switch, Verify"
1. Trigger a fresh backup on Minio (ensures latest data captured)
2. rclone sync from Minio to Garage (per server name, with `--checksum`)
3. Update ObjectStore resources to point to Garage
4. Trigger a new backup on Garage
5. **Mandatory**: restore from Garage backup into a test cluster and verify data matches the live database

**Success Criteria Per Cluster**:
- Data is successfully transferred to Garage (rclone sizes match)
- A new backup completes to Garage
- A recovery cluster can be created from the Garage backup
- Data in the recovery cluster matches the live database (row counts on key tables)

## Quick Start (Resume Migration)

**Current State**: All 7 clusters migrated (2026-02-07). Phase 4 cleanup (remove Minio ExternalSecrets) due 2026-02-14.

**To resume**:
1. Open this file
2. Read [Lessons Learned](#lessons-learned) for gotchas discovered during mealie migration
3. Jump to [Per-Cluster Migration Procedure](#per-cluster-migration-procedure)
4. Follow Phase 0 through Phase 4 step-by-step

**What's Already Done**:
- Garage credentials in Bitwarden (UUID: `5879ba4f-f80f-432e-ade2-d3a1281b3060`)
- ExternalSecrets deployed for all clusters
- Kustomizations updated to include Garage secrets
- Credentials tested (HTTP 200 OK to `s3.garage.internal`)
- mealie-16-db fully migrated and verified (2026-02-07)
- wallabag-16-db fully migrated and verified (2026-02-07)
- miniflux-16-db fully migrated and verified (2026-02-07)
- wikijs-16-db fully migrated and verified (2026-02-07)
- n8n-16-db fully migrated and verified (2026-02-07)
- hass-16-db fully migrated and verified (2026-02-07)

**What's Left Per Cluster**:
1. Phase 0: Pre-sync bulk data (optional, can run days before)
2. Phase 1: Pre-migration prep (verify health, record row counts — see lessons learned for backup step)
3. Phase 2: Migration execution (sync, switch ObjectStores)
4. Phase 3: Validation (**mandatory restore test with data verification**)
5. Phase 4: Cleanup (7 days later, remove Minio resources)

## Clusters to Migrate

Listed in recommended migration order (low activity → high activity):

| # | Cluster Name | Namespace | Storage | Server Name | External Server | isWALArchiver | Stop Service? | Status |
|---|--------------|-----------|---------|-------------|-----------------|---------------|---------------|--------|
| 1 | ~~**mealie-16-db**~~ | self-hosted | 5Gi | mealie-16-v5 | mealie-16-v4 | `true` (keep) | No | **Migrated 2026-02-07** |
| 2 | ~~**wallabag-16-db**~~ | self-hosted | 5Gi | wallabag-16-v5 | wallabag-16-v4 | absent | No | **Migrated 2026-02-07** |
| 3 | ~~**miniflux-16-db**~~ | self-hosted | 5Gi | miniflux-16-v5 | miniflux-16-v4 | absent | No | **Migrated 2026-02-07** |
| 4 | ~~**wikijs-16-db**~~ | self-hosted | 5Gi | wikijs-16-v5 | wikijs-16-v4 | absent | No | **Migrated 2026-02-07** |
| 5 | ~~**n8n-16-db**~~ | ai | 5Gi | n8n-16-v1 | N/A | absent | No | **Migrated 2026-02-07** |
| 6 | ~~**hass-16-db**~~ | home-automation | 10Gi | hass-16-v4 | hass-16-v3 | `true` (keep) | **Yes** | **Migrated 2026-02-07** |
| 7 | ~~**immich-16-db**~~ | media | 10Gi | immich-16-db | immich-16-db | `false` (keep) | **Yes** | **Migrated 2026-02-07** |

**Notes**:
- All clusters have 3 instances with `podAntiAffinityType: required`
- hass and immich receive data continuously (sensors / photo uploads) — their application services must be stopped during migration to prevent data inconsistency
- The other 5 clusters only change on user interaction, so stopping the service is unnecessary
- immich uses a custom image (`tensorchord/cloudnative-vectorchord:16-0.4.3`) — recovery tests must use this image

### Files Modified Per Cluster

Each cluster migration modifies files in `kubernetes/base/apps/<namespace>/<app>/db/`:

| File | Change |
|------|--------|
| `objectstore-backup.yaml` | Switch endpoint + credentials from Minio to Garage (keep `wal:` section) |
| `objectstore-external.yaml` (if exists) | Same as above |
| `cnpg-minio-external-secret.yaml` | Delete (Phase 4, 7 days later) |

> **NOTE**: Do NOT modify `pg-cluster-16.yaml` or remove `isWALArchiver` / `wal:` sections. WAL archiving is required for backup recovery. See [Lesson 6](#6-wal-archiving-cannot-be-disabled).

## Preparation Work Completed

The following preparation work has been completed (2026-01-11):

### Prerequisites Completed

1. **Garage Credentials Created in Bitwarden**
   - UUID: `5879ba4f-f80f-432e-ade2-d3a1281b3060`
   - Fields: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
   - Verified accessible via `bitwarden-fields` ClusterSecretStore

2. **Garage ExternalSecrets Deployed**
   - Created for all 7 clusters:
     - `cnpg-garage-access-mealie` (self-hosted)
     - `cnpg-garage-access-wallabag` (self-hosted)
     - `cnpg-garage-access-miniflux` (self-hosted)
     - `cnpg-garage-access-wikijs` (self-hosted)
     - `cnpg-garage-access-hass` (home-automation)
     - `cnpg-garage-access-immich` (media)
     - `cnpg-garage-access-n8n` (ai)
   - All synced successfully from Bitwarden

3. **Kustomizations Updated**
   - `cnpg-garage-external-secret.yaml` added to all cluster kustomizations
   - ArgoCD synced and applied

4. **Credentials Validated**
   - HTTP 200 OK from pod to `https://s3.garage.internal/cloudnative-pg/`
   - `rclone lsd garage:cloudnative-pg` works from cardinal

5. **Cardinal Backup Automation Already Targets Garage**
   - `nixos/hosts/cardinal/backups/local/rclone-garage-cloudnative-pg.nix` syncs `garage:cloudnative-pg` to `/srv/backup/garage/cloudnative-pg/` daily at 08:00
   - Once data lands in Garage, cardinal automatically creates local backup copies

## Per-Cluster Migration Procedure

### Variable Setup

Set these at the start of each cluster's migration:

```bash
# Adjust per cluster (see cluster table above)
export CLUSTER_NAME="mealie-16-db"
export NAMESPACE="self-hosted"
export APP="mealie"
export SERVER_NAME="mealie-16-v5"
export EXTERNAL_SERVER_NAME="mealie-16-v4"  # Leave empty if N/A
export DB_NAME="mealie"                      # Database name inside the cluster
export DB_USER="mealie"                      # Database owner
```

### Phase 0: Pre-Migration Data Sync (Bulk Transfer)

**Timing**: 1-7 days before migration window (while cluster runs normally)
**Purpose**: Transfer the bulk of existing backups so the actual switchover is fast.

#### 0.1 Initial Bulk Sync

**Execute on `cardinal` host**:

```bash
ssh cardinal.internal

SERVER_NAME="mealie-16-v5"           # Adjust per cluster
EXTERNAL_SERVER_NAME="mealie-16-v4"  # Adjust per cluster (leave empty if N/A)

# Sync primary backup data
rclone sync \
  minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  garage:cloudnative-pg/${SERVER_NAME} \
  --progress \
  --checksum \
  --transfers 8 \
  --checkers 16 \
  --log-file /tmp/cnpg-pre-sync-${SERVER_NAME}.log

# Sync external recovery data (if applicable)
if [ -n "${EXTERNAL_SERVER_NAME}" ]; then
  rclone sync \
    minio-cnpg:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    garage:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    --progress \
    --checksum \
    --transfers 8 \
    --checkers 16 \
    --log-file /tmp/cnpg-pre-sync-${EXTERNAL_SERVER_NAME}.log
fi
```

#### 0.2 Verify Pre-Sync

```bash
echo "Minio ${SERVER_NAME}:"
rclone size minio-cnpg:cloudnative-pg/${SERVER_NAME}

echo "Garage ${SERVER_NAME}:"
rclone size garage:cloudnative-pg/${SERVER_NAME}

if [ -n "${EXTERNAL_SERVER_NAME}" ]; then
  echo "Minio ${EXTERNAL_SERVER_NAME}:"
  rclone size minio-cnpg:cloudnative-pg/${EXTERNAL_SERVER_NAME}
  echo "Garage ${EXTERNAL_SERVER_NAME}:"
  rclone size garage:cloudnative-pg/${EXTERNAL_SERVER_NAME}
fi
```

**Success Criteria**: Garage shows similar total size to Minio (may differ slightly due to ongoing backups to Minio).

### Phase 1: Pre-Migration Preparation

**Timing**: Immediately before migration window.

#### 1.1 Verify Cluster Health

```bash
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}
kubectl get backup -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}
```

**Expected**: Cluster healthy, recent backups exist.

#### 1.2 Backup Current Configs (for rollback)

```bash
mkdir -p /tmp/cnpg-migration-backup/${CLUSTER_NAME}

kubectl get objectstore -n ${NAMESPACE} -o yaml > \
  /tmp/cnpg-migration-backup/${CLUSTER_NAME}/objectstores-before.yaml

kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} -o yaml > \
  /tmp/cnpg-migration-backup/${CLUSTER_NAME}/cluster-before.yaml
```

#### 1.3 Stop Application Service (hass and immich ONLY)

**Skip this step for mealie, wallabag, miniflux, wikijs, and n8n** — those only change on user interaction and the migration window is short enough to be safe.

**For hass-16-db**:
```bash
# Scale down Home Assistant to stop writes to the database
kubectl scale deployment homeassistant -n home-automation --replicas=0

# Verify pod is gone
kubectl get pods -n home-automation -l app=homeassistant
# Expected: No resources found
```

**For immich-16-db**:
```bash
# Scale down Immich server and ML to stop all writes
kubectl scale deployment immich-server -n media --replicas=0
kubectl scale deployment immich-machine-learning -n media --replicas=0

# Verify pods are gone
kubectl get pods -n media -l app.kubernetes.io/instance=immich
# Expected: Only Redis and DB pods remain
```

#### 1.4 Record Row Counts (for later verification)

Query the live database to record baseline row counts. Run on the primary pod:

```bash
PRIMARY_POD=$(kubectl get pods -n ${NAMESPACE} \
  -l cnpg.io/cluster=${CLUSTER_NAME},role=primary \
  -o jsonpath='{.items[0].metadata.name}')

# Run the verification queries (adjust per cluster — see "Data Verification Queries" section)
# NOTE: Use -U postgres (peer auth rejects app users from kubectl exec)
kubectl exec -n ${NAMESPACE} ${PRIMARY_POD} -- \
  psql -U postgres -d ${DB_NAME} -c "<QUERY>"
```

Save the output. See [Data Verification Queries](#data-verification-queries) for per-cluster queries.

#### 1.5 Trigger Pre-Migration Backup

> **IMPORTANT**: `kubectl cnpg backup` defaults to the `barmanObjectStore` method, which fails because the clusters use the **plugin** method (managed by ArgoCD via ScheduledBackup resources). You must create a Backup resource with `method: plugin` explicitly. See the [Lessons Learned](#lessons-learned) section.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${CLUSTER_NAME}-pre-migration
  namespace: ${NAMESPACE}
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: ${CLUSTER_NAME}
EOF

# Watch for completion
kubectl get backup.postgresql.cnpg.io ${CLUSTER_NAME}-pre-migration -n ${NAMESPACE} -w
```

**Expected**: Backup completes within 5-15 minutes. **Never skip this step** — always trigger a fresh backup immediately before migration to ensure the latest data is captured.

### Phase 2: Migration Execution

#### 2.1 Delta Sync (Catch Up Since Phase 0)

**Execute on `cardinal` host**:

```bash
ssh cardinal.internal

SERVER_NAME="mealie-16-v5"           # Adjust per cluster
EXTERNAL_SERVER_NAME="mealie-16-v4"  # Adjust per cluster

# Delta sync — only transfers new files since Phase 0
rclone sync \
  minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  garage:cloudnative-pg/${SERVER_NAME} \
  --progress \
  --checksum \
  --transfers 8 \
  --checkers 16 \
  --log-file /tmp/cnpg-delta-sync-${SERVER_NAME}.log

if [ -n "${EXTERNAL_SERVER_NAME}" ]; then
  rclone sync \
    minio-cnpg:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    garage:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    --progress \
    --checksum \
    --transfers 8 \
    --checkers 16 \
    --log-file /tmp/cnpg-delta-sync-${EXTERNAL_SERVER_NAME}.log
fi
```

#### 2.2 Verify Sync Completeness

```bash
echo "Minio ${SERVER_NAME}:"
rclone size minio-cnpg:cloudnative-pg/${SERVER_NAME}

echo "Garage ${SERVER_NAME}:"
rclone size garage:cloudnative-pg/${SERVER_NAME}

# Sizes MUST match exactly (application stopped for hass/immich, no new writes for others)
```

**Gate**: Do NOT proceed unless sizes match exactly.

#### 2.3 Update ObjectStore Resources

Edit both ObjectStore files to point to Garage. **Keep the `wal:` section intact** — WAL archiving is required for recovery.

**`objectstore-backup.yaml`** — make these changes:

| Field | Before | After |
|-------|--------|-------|
| `endpointURL` | `https://s3.internal` | `https://s3.garage.internal` |
| `endpointCA.name` | `cnpg-minio-access-<app>` | `cnpg-garage-access-<app>` |
| `s3Credentials.accessKeyId.name` | `cnpg-minio-access-<app>` | `cnpg-garage-access-<app>` |
| `s3Credentials.secretAccessKey.name` | `cnpg-minio-access-<app>` | `cnpg-garage-access-<app>` |

> **WARNING**: Do NOT remove the `wal:` section. See [Lesson 6](#6-wal-archiving-cannot-be-disabled).

**`objectstore-external.yaml`** (if exists) — same changes as above.

**Target state for an ObjectStore** (example: mealie):

```yaml
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: mealie-backup-store
spec:
  configuration:
    destinationPath: s3://cloudnative-pg/
    endpointURL: https://s3.garage.internal
    endpointCA:
      name: cnpg-garage-access-mealie
      key: tls.crt
    s3Credentials:
      accessKeyId:
        name: cnpg-garage-access-mealie
        key: aws-access-key-id
      secretAccessKey:
        name: cnpg-garage-access-mealie
        key: aws-secret-access-key
    data:
      compression: bzip2
    wal:
      compression: bzip2
      maxParallel: 8
  retentionPolicy: "30d"
```

Apply:

```bash
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/objectstore-backup.yaml

# If objectstore-external.yaml exists:
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/objectstore-external.yaml
```

#### 2.4 Rolling Restart (REQUIRED)

> **CRITICAL**: ObjectStore changes do NOT trigger a pod restart. WAL archiving will continue to the old endpoint until pods are restarted. See [Lesson 9](#9-objectstore-changes-require-a-rolling-restart).

After committing and pushing, **sync the ArgoCD application first** to ensure the new ObjectStore resources are applied before restarting:

```bash
# Sync ArgoCD app to apply the new ObjectStores
argocd app sync <app-name> --grpc-web
# Or use the ArgoCD UI to trigger a sync/refresh

# Verify the ObjectStores are updated
kubectl get objectstore -n ${NAMESPACE} -o yaml | grep endpointURL
# Must show: https://s3.garage.internal
```

Then restart the cluster:

```bash
kubectl cnpg restart ${CLUSTER_NAME} -n ${NAMESPACE}
```

Then verify WALs go to Garage (force a WAL switch and check logs):

```bash
PRIMARY_POD=$(kubectl get pods -n ${NAMESPACE} \
  -l cnpg.io/cluster=${CLUSTER_NAME},role=primary \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n ${NAMESPACE} ${PRIMARY_POD} -c postgres -- \
  psql -U postgres -c "SELECT pg_switch_wal();"

sleep 10

kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} \
  --all-containers --since=30s | grep "barman-cloud-wal-archive"
# Must show: --endpoint-url https://s3.garage.internal
```

Wait for the cluster to return to healthy state (3/3 ready, ~60 seconds).

#### 2.5 Restart Application Service (hass and immich ONLY)

**For hass-16-db**:
```bash
kubectl scale deployment homeassistant -n home-automation --replicas=1

# Verify pod is running
kubectl get pods -n home-automation -l app=homeassistant
```

**For immich-16-db**:
```bash
kubectl scale deployment immich-server -n media --replicas=1
kubectl scale deployment immich-machine-learning -n media --replicas=1

# Verify pods are running
kubectl get pods -n media -l app.kubernetes.io/instance=immich
```

### Phase 3: Validation (Mandatory)

#### 3.1 Trigger Test Backup to Garage

> **IMPORTANT**: Must use `method: plugin`, not `kubectl cnpg backup` (see [Lessons Learned](#lessons-learned)).

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${CLUSTER_NAME}-post-migration
  namespace: ${NAMESPACE}
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: ${CLUSTER_NAME}
EOF

# Watch for completion
kubectl get backup.postgresql.cnpg.io ${CLUSTER_NAME}-post-migration -n ${NAMESPACE} -w
```

**Expected**: Backup completes successfully. Clean up the ad-hoc Backup resource afterwards to avoid ArgoCD drift:

```bash
kubectl delete backup.postgresql.cnpg.io ${CLUSTER_NAME}-post-migration -n ${NAMESPACE}
```

#### 3.2 Verify Backup Exists in Garage

```bash
ssh cardinal.internal "
echo 'Backups in Garage for ${SERVER_NAME}:'
rclone ls garage:cloudnative-pg/${SERVER_NAME}/base/ | tail -20
"
```

**Expected**: New backup directory visible.

#### 3.3 Restore Test (MANDATORY)

Create a single-instance recovery cluster from the Garage backup and verify data integrity.

**Create the recovery cluster manifest** (`/tmp/recovery-test-${APP}.yaml`):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}-recovery-test
  namespace: ${NAMESPACE}
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-27  # SEE NOTE FOR IMMICH
  primaryUpdateStrategy: unsupervised

  affinity:
    nodeSelector:
      opi.feature.node.kubernetes.io/5plus: "true"

  storage:
    size: 5Gi  # Match or exceed original cluster size
    storageClass: openebs-hostpath

  bootstrap:
    recovery:
      source: clusterBackup

  externalClusters:
    - name: clusterBackup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: ${APP}-backup-store  # Points to Garage ObjectStore
          serverName: ${SERVER_NAME}
```

**IMMICH EXCEPTION**: For immich-16-db, use the custom image and include extensions:

```yaml
  imageName: ghcr.io/tensorchord/cloudnative-vectorchord:16-0.4.3
  postgresql:
    shared_preload_libraries:
      - "vchord.so"
  # storage.size: 10Gi for immich
```

Apply and wait for recovery:

```bash
kubectl apply -f /tmp/recovery-test-${APP}.yaml

# Watch recovery progress (may take 5-15 minutes)
kubectl get cluster ${CLUSTER_NAME}-recovery-test -n ${NAMESPACE} -w

# Wait until status shows "Cluster in healthy state"
```

#### 3.4 Verify Data Matches (MANDATORY)

Query both the live cluster and the recovery cluster, then compare row counts.

```bash
# Get pod names
PRIMARY_POD=$(kubectl get pods -n ${NAMESPACE} \
  -l cnpg.io/cluster=${CLUSTER_NAME},role=primary \
  -o jsonpath='{.items[0].metadata.name}')

RECOVERY_POD=$(kubectl get pods -n ${NAMESPACE} \
  -l cnpg.io/cluster=${CLUSTER_NAME}-recovery-test \
  -o jsonpath='{.items[0].metadata.name}')

# Run verification queries on LIVE cluster
# NOTE: Use -U postgres (peer auth rejects app users from kubectl exec)
echo "=== LIVE CLUSTER ==="
kubectl exec -n ${NAMESPACE} ${PRIMARY_POD} -- \
  psql -U postgres -d ${DB_NAME} -c "<VERIFICATION_QUERY>"

# Run same queries on RECOVERY cluster
echo "=== RECOVERY CLUSTER ==="
kubectl exec -n ${NAMESPACE} ${RECOVERY_POD} -- \
  psql -U postgres -d ${DB_NAME} -c "<VERIFICATION_QUERY>"
```

See [Data Verification Queries](#data-verification-queries) for per-cluster queries.

**Gate**: Row counts must match. For hass/immich, counts should match exactly since the service was stopped during migration. For other clusters, counts may differ very slightly if a user interacted during migration — this is acceptable as long as the pre-migration backup counts match.

#### 3.5 Cleanup Recovery Test Cluster

```bash
kubectl delete cluster ${CLUSTER_NAME}-recovery-test -n ${NAMESPACE}

# Wait for PVCs to be cleaned up
kubectl get pvc -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}-recovery-test
```

### Phase 4: Cleanup and Commit

**Timing**: Execute 7 days after successful migration.

#### 4.1 Remove Old Minio ExternalSecret

```bash
# Delete from cluster
kubectl delete externalsecret cnpg-minio-access-${APP} -n ${NAMESPACE}
kubectl delete secret cnpg-minio-access-${APP} -n ${NAMESPACE}

# Remove cnpg-minio-external-secret.yaml from kustomization.yaml
# Remove the file from git
```

#### 4.2 Archive Minio Backup Data (safety copy)

```bash
ssh cardinal.internal

# Archive to local disk on cardinal
rclone sync minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  /srv/backups/cnpg-migration-archive/${SERVER_NAME}/ \
  --progress

# Keep for 90 days before considering deletion
```

#### 4.3 Commit Changes

```bash
cd /home/ndufour/Documents/code/projects/avalanche

git add kubernetes/base/apps/${NAMESPACE}/${APP}/db/
git commit -m "feat(cnpg): migrate ${CLUSTER_NAME} backups to Garage S3

- Update ObjectStore resources to point to s3.garage.internal
- Switch credentials from cnpg-minio-access to cnpg-garage-access
- WAL archiving kept enabled (required for recovery)
- Restore test passed: data verified against live cluster

Ref: #31, docs/plans/cnpg-minio-to-garage-migration.md"

git push
```

## Data Verification Queries

Per-cluster queries to verify data integrity after restore. Run against both the live cluster and the recovery cluster.

### mealie-16-db

```sql
SELECT 'recipes' AS table_name, count(*) FROM recipes
UNION ALL
SELECT 'users', count(*) FROM users;
```

### wallabag-16-db

```sql
SELECT 'wallabag_entry' AS table_name, count(*) FROM wallabag_entry
UNION ALL
SELECT 'wallabag_user', count(*) FROM wallabag_user;
```

### miniflux-16-db

```sql
SELECT 'entries' AS table_name, count(*) FROM entries
UNION ALL
SELECT 'feeds', count(*) FROM feeds;
```

### wikijs-16-db

```sql
SELECT 'pages' AS table_name, count(*) FROM pages
UNION ALL
SELECT 'users', count(*) FROM users;
```

### n8n-16-db

```sql
SELECT 'workflow_entity' AS table_name, count(*) FROM workflow_entity
UNION ALL
SELECT 'credentials_entity', count(*) FROM credentials_entity;
```

### hass-16-db

```sql
SELECT 'states' AS table_name, count(*) FROM states
UNION ALL
SELECT 'statistics' AS table_name, count(*) FROM statistics;
```

**Note**: hass counts should match exactly since Home Assistant is stopped during migration.

### immich-16-db

```sql
SELECT 'asset' AS table_name, count(*) FROM asset
UNION ALL
SELECT 'user', count(*) FROM "user";
```

**Note**: immich counts should match exactly since the Immich server is stopped during migration. The `user` table must be double-quoted because it is a PostgreSQL reserved word.

> **Verified**: All table names confirmed against live databases on 2026-02-07.

## Lessons Learned

Discovered during the mealie-16-db migration (2026-02-07):

### 1. `kubectl cnpg backup` defaults to the wrong method

`kubectl cnpg backup` creates a Backup with `method: barmanObjectStore`, which fails with `no barmanObjectStore section defined on the target cluster`. All clusters in this repo use `method: plugin` (Barman Cloud Plugin managed by ArgoCD). **Always create Backup resources as YAML with `method: plugin`** instead of using `kubectl cnpg backup`.

### 2. Clean up ad-hoc Backup resources after use

Ad-hoc Backup resources (pre-migration, post-migration) are not managed by ArgoCD and will show as drift. Delete them after confirming they completed:
```bash
kubectl delete backup.postgresql.cnpg.io ${CLUSTER_NAME}-post-migration -n ${NAMESPACE}
```

### 3. Removing `isWALArchiver` triggers a rolling restart

Removing `isWALArchiver: true` from `pg-cluster-16.yaml` causes CNPG to perform a rolling restart of all instances. During the restart, the cluster temporarily shows 2/3 ready instances for about 60 seconds. This is expected and safe — the cluster returns to healthy state automatically.

### 4. `rclone sync` deletes files in Garage that don't exist in Minio

The `rclone sync` command deletes files at the destination that don't exist at the source. During the mealie migration, this removed 146 older files (97 MiB) from Garage that had been there from a previous test sync but had since been purged from Minio by the 30-day retention policy. This is correct behavior — Garage should mirror Minio's current state. Just be aware that Garage file counts may decrease after sync.

### 5. Phase 0 can be folded into Phase 2 for small clusters

For mealie (~116 MiB), the full sync took 8 seconds. For clusters this small, there's no need for a separate pre-sync phase days ahead — just do it all in Phase 2. Larger clusters (hass, immich) should still pre-sync.

### 6. WAL archiving CANNOT be disabled

**Discovered during wallabag migration (2026-02-07).** Removing the `wal:` section from ObjectStore specs causes backups to become **non-recoverable**. Even though backups complete successfully, recovery fails with `could not locate required checkpoint record` because the WAL segments needed to replay from the base backup's checkpoint are missing.

The Barman Cloud Plugin requires archived WAL segments alongside base backups to perform recovery — this is fundamental to how PostgreSQL point-in-time recovery works. There is no "daily backup only" mode.

**Impact**: The original plan instructed removing `wal:` sections and `isWALArchiver`. This was reverted for mealie (which had `isWALArchiver: true` temporarily removed, then restored) and wallabag (which never had it but had `wal:` sections removed then restored). All subsequent clusters must **keep WAL archiving intact**.

### 7. RBAC propagation delay after ObjectStore credential changes

Discovered during wallabag migration: the first backup attempt after switching ObjectStore credentials may fail with a "forbidden" RBAC error (e.g., `secrets cnpg-garage-access-wallabag is forbidden`). This is a timing issue — the CNPG operator needs a few seconds to update the Role binding for the new secret name. Retry after ~10 seconds resolves it.

### 8. Take a fresh backup after any WAL archiving disruption

If WAL archiving was interrupted (even briefly), any existing backups taken during the disruption may be non-recoverable. Always trigger a new backup after confirming WAL archiving is stable (`ContinuousArchiving: True`), and verify recovery from that fresh backup — not from older ones.

### 9. ObjectStore changes require a rolling restart

**Discovered during miniflux migration (2026-02-07).** Changing the ObjectStore endpoint/credentials does NOT trigger a pod restart. The WAL archiver reads its config at pod startup — so after updating ObjectStores, the running pods continue archiving WALs to the **old** endpoint (Minio). Backups work correctly (the plugin reads the ObjectStore at runtime), but WAL archiving does not.

**Fix**: After committing and pushing ObjectStore changes, run:
```bash
kubectl cnpg restart ${CLUSTER_NAME} -n ${NAMESPACE}
```
Then verify WALs go to Garage:
```bash
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --all-containers --since=60s | grep "barman-cloud-wal-archive"
# Must show: --endpoint-url https://s3.garage.internal
```

**Why mealie/wallabag didn't hit this**: mealie had `isWALArchiver` removed (triggering restart), wallabag had WAL config restored (triggering restart). Clusters with ObjectStore-only changes (miniflux, wikijs, n8n) will all need an explicit restart.

## Cluster-Specific Notes

### mealie-16-db — Migrated 2026-02-07

- **Namespace**: self-hosted
- **Server Name**: mealie-16-v5
- **External Server**: mealie-16-v4
- **Commit**: `b63009b`

**Migration results**:
- rclone sync: 245 objects / 116.459 MiB (mealie-16-v5), 43 objects / 14.833 MiB (mealie-16-v4) — exact match
- Sync duration: 8 seconds total (both server names)
- Post-migration backup to Garage: completed in 9 seconds
- Recovery test: cluster reached healthy state, data verified (6 recipes, 2 users — exact match)
- Rolling restart after `isWALArchiver` removal: ~60 seconds, 2/3 ready briefly, then 3/3 healthy
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### wallabag-16-db — Migrated 2026-02-07

- **Namespace**: self-hosted
- **Server Name**: wallabag-16-v5
- **External Server**: wallabag-16-v4
- **Commit**: `44a1a78` (final fix with WAL restored)

**Migration results**:
- rclone sync: 243 objects / 267.713 MiB (wallabag-16-v5), 36 objects / 31.887 MiB (wallabag-16-v4) — exact match
- Pre-migration backup: completed in 10 seconds
- Post-migration backup to Garage: completed (after RBAC retry — see Lesson 7)
- Recovery test: cluster reached healthy state, data verified (572 wallabag_entry, 2 wallabag_user — exact match)
- **Incident**: Initial attempt removed `wal:` sections per original plan, which caused recovery to fail with "could not locate required checkpoint record". WAL config was restored, a fresh backup taken, and recovery succeeded on second attempt. See Lessons 6 and 8.
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### miniflux-16-db — Migrated 2026-02-07

- **Namespace**: self-hosted
- **Server Name**: miniflux-16-v5
- **External Server**: miniflux-16-v4
- **Commit**: `6e44f60`

**Migration results**:
- rclone sync: 2571 objects / 1.349 GiB (miniflux-16-v5), 224 objects / 156.040 MiB (miniflux-16-v4) — exact match
- Pre-migration backup: completed
- **Incident**: First recovery test failed with "invalid checkpoint record" — WAL archiver was still writing to Minio (`s3.internal`) because ObjectStore changes alone don't trigger a pod restart. Required `kubectl cnpg restart` to pick up the new endpoint. See Lesson 9.
- Post-migration backup (after restart): completed, WALs confirmed going to Garage
- Recovery test: cluster reached healthy state, data verified (2709 entries, 23 feeds — exact match)
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### wikijs-16-db — Migrated 2026-02-07

- **Namespace**: self-hosted
- **Server Name**: wikijs-16-v5
- **External Server**: wikijs-16-v4
- **Commit**: `7f7db2c`

**Migration results**:
- rclone sync: 9010 objects / 155.159 MiB (wikijs-16-v5), 47 objects / 16.795 MiB (wikijs-16-v4) — exact match
- Rolling restart performed (Lesson 9), WALs confirmed going to Garage
- Post-migration backup: completed
- Recovery test: cluster reached healthy state, data verified (41 pages, 2 users — exact match)
- Clean migration — no incidents
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### n8n-16-db — Migrated 2026-02-07

- **Namespace**: ai
- **Server Name**: n8n-16-v1
- **External Server**: N/A
- **Commit**: `57824d7`

**Migration results**:
- rclone sync: 155 objects / 19.589 MiB (n8n-16-v1) — exact match
- Rolling restart performed (Lesson 9), WALs confirmed going to Garage
- Post-migration backup: completed
- Recovery test: cluster reached healthy state, data verified (0 workflows, 0 credentials — exact match, fresh instance)
- Clean migration — no incidents
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### hass-16-db — Migrated 2026-02-07

- **Namespace**: home-automation
- **Server Name**: hass-16-v4
- **External Server**: hass-16-v3
- **Commit**: `95250b9`

**Migration results**:
- Home Assistant stopped (scaled to 0) before migration — ArgoCD sync disabled to prevent auto-restore
- Frozen row counts: 1,307,561 states, 354,845 statistics
- rclone sync: 9276 objects / 15.610 GiB (hass-16-v4), 908 objects / 1.414 GiB (hass-16-v3) — exact match
- ObjectStores applied manually via kubectl (ArgoCD sync was disabled)
- Rolling restart performed, WALs confirmed going to Garage
- Post-migration backup: completed (~2.5 min for 1.7 GB database)
- Recovery test: cluster reached healthy state, data verified (1,307,561 states, 354,845 statistics — exact match with frozen counts)
- ArgoCD sync re-enabled, Home Assistant restarted and running
- Clean migration — no incidents
- Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

### immich-16-db

- **Namespace**: media
- **Server Name**: immich-16-db
- **External Server**: immich-16-db (same name — used in externalClusters for recovery)
- **Has isWALArchiver**: `false` (explicit) — kept as-is
- **Image**: `ghcr.io/tensorchord/cloudnative-vectorchord:16-0.4.3` (custom VectorChord)
- **Storage**: 10Gi
- **Migrated**: 2026-02-07
- **Results**:
  - rclone: 1233 objects / 1.161 GiB — exact match
  - Application NOT stopped (single user, no uploads during migration)
  - Rolling restart after ArgoCD sync — WALs confirmed to Garage
  - Recovery test used VectorChord image with `shared_preload_libraries: ["vchord.so"]`
  - Recovery verification: 302 assets, 1 user — exact match
  - Clean migration — no incidents
  - Phase 4 cleanup (remove Minio ExternalSecret): due 2026-02-14

## Rollback Procedure

### Immediate Rollback (During Migration)

**Step 1**: Restore ObjectStores from backup:

```bash
kubectl apply -f /tmp/cnpg-migration-backup/${CLUSTER_NAME}/objectstores-before.yaml
```

**Step 2**: Restore cluster manifest if changed:

```bash
kubectl apply -f /tmp/cnpg-migration-backup/${CLUSTER_NAME}/cluster-before.yaml
```

**Step 3**: If service was stopped, restart it:

```bash
# hass
kubectl scale deployment homeassistant -n home-automation --replicas=1

# immich
kubectl scale deployment immich-server -n media --replicas=1
kubectl scale deployment immich-machine-learning -n media --replicas=1
```

**Step 4**: Verify backups resume to Minio:

```bash
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}
```

### Post-Migration Rollback (Days Later)

If issues found after migration:

1. Verify Minio data is still intact: `rclone ls minio-cnpg:cloudnative-pg/${SERVER_NAME}/base/`
2. Sync any new backups from Garage back to Minio: `rclone sync garage:cloudnative-pg/${SERVER_NAME} minio-cnpg:cloudnative-pg/${SERVER_NAME} --checksum`
3. Revert ObjectStore and cluster manifests from git history
4. Apply reverted manifests

## Success Criteria (Per Cluster)

Migration is considered successful ONLY when ALL criteria are met:

- [ ] Pre-migration backup completed on Minio
- [ ] rclone sync completed with 0 errors
- [ ] Minio and Garage sizes match exactly for all server names
- [ ] ObjectStore resources updated to `s3.garage.internal`
- [ ] `wal:` section preserved in all ObjectStore specs
- [ ] Post-migration backup completed successfully to Garage
- [ ] **Recovery test cluster boots and reaches healthy state**
- [ ] **Data verification: row counts match between live and recovery cluster**
- [ ] Recovery test cluster cleaned up
- [ ] Application service restarted (hass/immich only) and functioning
- [ ] No errors in backup logs for 24 hours
- [ ] Changes committed and pushed to git

## Timeline Estimate (Per Cluster)

| Phase | Duration | Notes |
|-------|----------|-------|
| Phase 0: Pre-sync (bulk) | 5 min - 6 hours | Run days before; varies by cluster size |
| Phase 1: Pre-migration prep | 15-30 min | Health check, stop service (if needed), record counts, trigger backup |
| Phase 2: Migration execution | 10-20 min | Delta sync, update ObjectStores, update cluster manifest |
| Phase 3: Validation | 30-45 min | New backup, restore test, data verification |
| **Total per cluster** | **~60-90 min** | Hands-on time (excluding Phase 0) |

**Full migration (7 clusters)**: Spread over 2-4 weeks, 1 cluster per session. ~8-10 hours total hands-on time.

## References

### Documentation

- [Barman Cloud Plugin - Object Stores](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/)
- [Barman Cloud Plugin - Migration Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/)
- [CloudNative-PG - Recovery](https://cloudnative-pg.io/documentation/preview/recovery/)

### Internal

- `CLAUDE.md` — Infrastructure overview
- Issue #31 — Original migration request
- `nixos/hosts/cardinal/backups/local/rclone-garage-cloudnative-pg.nix` — Automated Garage → local backup

## Appendix: Verification Commands Cheat Sheet

```bash
# Set variables
export CLUSTER_NAME="mealie-16-db"
export NAMESPACE="self-hosted"
export APP="mealie"
export SERVER_NAME="mealie-16-v5"

# Cluster health
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}

# Recent backups
kubectl get backup -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}

# ObjectStore resources
kubectl get objectstore -n ${NAMESPACE}

# ExternalSecrets
kubectl get externalsecret -n ${NAMESPACE} | grep -E "minio|garage"

# Cluster logs
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=100

# Error grep
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=500 | grep -i error

# Backup in Garage (from cardinal)
ssh cardinal.internal "rclone ls garage:cloudnative-pg/${SERVER_NAME}/base/"
```

---

**END OF DOCUMENT**
