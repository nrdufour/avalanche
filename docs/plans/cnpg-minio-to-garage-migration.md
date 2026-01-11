# CloudNative-PG Backup Migration: Minio to Garage

**Status**: Planning
**Created**: 2026-01-11
**Migration Strategy**: Per-cluster, starting with low-activity clusters

## Executive Summary

This document outlines the comprehensive migration plan for moving all CloudNative-PG (CNPG) cluster backups from the existing Minio S3 server (`s3.internal`) to the new Garage S3 server (`s3.garage.internal`). The migration will be executed one cluster at a time to minimize risk and ensure data integrity.

**Critical Constraint**: This is production database backup data. Data loss is unacceptable.

**Migration Strategy**: "Pre-Sync, Pause, Delta-Sync, Switch"
1. **Phase 0** (days before): Bulk transfer existing backups to Garage while cluster runs normally (30min-6hrs depending on size)
2. **Phase 2** (migration window): Pause WAL archiving, quick delta sync (1-5min), switch to Garage, resume (~15-30min total)
3. **3-Pod HA Protection**: All clusters have 3 replicas with streaming replication, making the 15-30min WAL archiving gap safe (only catastrophic total cluster loss would be affected)

**Actual Migration Window**: 45-60 minutes per cluster (WAL archiving gap: 15-30 minutes)

## Background

### Current Architecture

- **Backup Backend**: Minio S3 server at `s3.internal`
- **Bucket**: `s3://cloudnative-pg/`
- **Backup Method**: Barman Cloud Plugin v0.7.0
- **Credentials**: Stored in Bitwarden, synced via ExternalSecrets
- **CA Certificate**: Ptinem Root CA (step-ca issued)
- **7 CNPG Clusters** across 3 namespaces

### Target Architecture

- **Backup Backend**: Garage S3 server at `s3.garage.internal`
- **Bucket**: `s3://cloudnative-pg/` (same path structure)
- **Backup Method**: Barman Cloud Plugin v0.7.0 (unchanged)
- **Credentials**: New Garage credentials in Bitwarden
- **CA Certificate**: Same Ptinem Root CA
- **WAL Archiving**: Continuous (no native pause feature)

## Scope

### Clusters to Migrate

Listed in recommended migration order (low activity → high activity):

| # | Cluster Name | Namespace | Instances | Storage | Server Name | External Server | Has Recovery |
|---|--------------|-----------|-----------|---------|-------------|-----------------|--------------|
| 1 | **mealie-16-db** | self-hosted | 3 | 5Gi | mealie-16-v5 | mealie-16-v4 | Yes |
| 2 | wger-16-db | self-hosted | 3 | 5Gi | wger-16-v1 | N/A | No |
| 3 | wallabag-16-db | self-hosted | 3 | 5Gi | wallabag-16-v5 | wallabag-16-v4 | Yes |
| 4 | miniflux-16-db | self-hosted | 3 | 5Gi | miniflux-16-v5 | miniflux-16-v4 | Yes |
| 5 | wikijs-16-db | self-hosted | 3 | 5Gi | wikijs-16-v5 | wikijs-16-v4 | Yes |
| 6 | hass-16-db | home-automation | 3 | 10Gi | hass-16-v4 | hass-16-v3 | Yes |
| 7 | immich-16-db | media | 3 | 10Gi | immich-16-db | N/A | No |

**Start with**: mealie-16-db (lowest activity, user-specified preference)

### Files Modified Per Cluster

Each cluster migration requires updating files in `kubernetes/base/apps/<namespace>/<app>/db/`:

1. **`objectstore-backup.yaml`** - Primary backup ObjectStore (always present)
2. **`objectstore-external.yaml`** - Recovery ObjectStore (only for clusters with externalClusters)
3. **`cnpg-minio-external-secret.yaml`** - Credentials ExternalSecret (rename to `cnpg-garage-external-secret.yaml`)

## Prerequisites

**Note**: If you're already running the initial rclone sync to Garage, excellent! That's Phase 0 (Pre-Migration Data Sync). You're on the right track. Complete the prerequisites below while that sync runs.

### 1. Garage Credentials Setup

Create a new Bitwarden entry for Garage S3 access:

**Location**: Bitwarden (accessible via `bitwarden-fields` ClusterSecretStore)
**Entry Name**: `CNPG Garage S3 Access`
**Fields Required**:
- `AWS_ACCESS_KEY_ID`: Garage access key
- `AWS_SECRET_ACCESS_KEY`: Garage secret key

**Reference**: Model after existing Minio credentials (UUID: `b616835a-f93f-408e-95e0-80a7f33b0a59`)

**Action**: Obtain the Bitwarden UUID for the new entry (needed for ExternalSecret manifests)

### 2. Garage Bucket Verification

Verify the target bucket exists and is accessible:

```bash
# From cardinal host (has rclone configured)
ssh cardinal.internal

# Test Garage access
rclone lsd garage: | grep cloudnative-pg

# If bucket doesn't exist, create it
rclone mkdir garage:cloudnative-pg
```

### 3. rclone Configuration on cardinal

Ensure `cardinal` host has both remotes configured:

```bash
ssh cardinal.internal

# Verify remotes exist
rclone listremotes | grep -E '(minio-cnpg|garage)'

# Expected output:
# minio-cnpg:
# garage:
```

If missing, configure using Garage credentials from prerequisite #1.

### 4. Verify CA Certificate

Both Minio and Garage use the same CA certificate (Ptinem Root CA). Verify:

```bash
# Current certificate in use
kubectl get secret cnpg-minio-access-mealie -n self-hosted -o jsonpath='{.data.tls\.crt}' | base64 -d
```

This certificate should work for both `s3.internal` and `s3.garage.internal`.

## Migration Architecture

### Key Decisions

#### 1. No Native Backup Pause Feature

**Finding**: CloudNative-PG and Barman Cloud Plugin do not provide a native "pause" or "suspend" feature for backups and WAL archiving.

**WAL Archiving Behavior**:
- Runs continuously (default `archive_timeout: 5min`)
- Cannot be paused without removing the plugin configuration
- Removing the plugin would break continuous archiving chain

**Implication**: We will temporarily disable the plugin, sync data, then atomically reconfigure to new ObjectStore.

#### 2. Migration Window Strategy

**Approach**: "Pre-Sync, Pause, Delta-Sync, Switch"

1. **Pre-Sync** (days/hours before): Bulk transfer all existing backups from Minio to Garage while cluster runs normally
2. **Pause**: Temporarily disable WAL archiving by removing `isWALArchiver: true` from plugin
3. **Delta-Sync**: Quick rclone sync to catch up any new WAL/backups created since pre-sync (< 5 minutes)
4. **Switch**: Update ObjectStore resources to point to Garage and re-enable WAL archiving

**Trade-off**: Brief period (15-30 minutes) without WAL archiving to object storage during migration window
**Mitigation**:
- Pre-sync minimizes actual migration window duration
- 3-pod HA setup protects against pod crashes during window
- Pre-migration backup provides known-good recovery point
- Retain Minio data as fallback

#### 3. High Availability Protection

**All clusters run with 3 instances**:
```yaml
instances: 3
podAntiAffinityType: required  # Forces replicas on different physical nodes
```

**WAL Replication**:
- WAL is continuously streamed: Primary → Standby #1 → Standby #2
- Standbys maintain near-real-time copies independent of object storage
- Failover happens automatically within 60 seconds

**Risk During WAL Archiving Gap**:
- ✅ **Single pod crash**: Standby promoted, zero data loss
- ✅ **Node failure**: Pod rescheduled or standby promoted, zero data loss
- ✅ **Two pods crash**: Remaining pod still has all data
- ⚠️ **All 3 pods + volumes lost simultaneously**: Would recover from pre-migration backup

**Conclusion**: The WAL archiving gap only matters for total cluster annihilation (datacenter-level disaster), not routine failures. The pre-migration backup (Phase 1.3) serves as the safety net for this extremely unlikely scenario.

#### 4. Data Continuity via rclone Sync

**Sync Command** (run from `cardinal` host):

```bash
rclone sync minio-cnpg:cloudnative-pg garage:cloudnative-pg \
  --progress \
  --checksum \
  --transfers 8 \
  --checkers 16 \
  --log-file /tmp/cnpg-migration-sync.log
```

**Rationale**:
- `--checksum`: Verify data integrity via checksums (slower but safer)
- `--transfers 8`: Parallel file transfers for speed
- `--log-file`: Audit trail of sync operation

**Verification**:

```bash
# Compare directory structures
rclone lsl minio-cnpg:cloudnative-pg > /tmp/minio-list.txt
rclone lsl garage:cloudnative-pg > /tmp/garage-list.txt
diff /tmp/minio-list.txt /tmp/garage-list.txt
```

## Per-Cluster Migration Procedure

### Phase 0: Pre-Migration Data Sync (Bulk Transfer)

**Timing**: Execute 1-7 days before migration window (while cluster runs normally)

**Purpose**: Transfer the bulk of existing backup data to Garage before the migration window, minimizing the actual switchover time.

#### 0.1 Initial Bulk Sync

**Execute on `cardinal` host**:

```bash
ssh cardinal.internal

# Set cluster-specific serverNames
SERVER_NAME="mealie-16-v5"  # Adjust per cluster
EXTERNAL_SERVER_NAME="mealie-16-v4"  # Adjust per cluster (if applicable)

# Sync primary backup data (this may take hours for large clusters)
rclone sync \
  minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  garage:cloudnative-pg/${SERVER_NAME} \
  --progress \
  --checksum \
  --transfers 8 \
  --checkers 16 \
  --log-file /tmp/cnpg-pre-migration-${SERVER_NAME}.log

# If cluster has external recovery serverName, sync that too
if [ -n "${EXTERNAL_SERVER_NAME}" ]; then
  rclone sync \
    minio-cnpg:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    garage:cloudnative-pg/${EXTERNAL_SERVER_NAME} \
    --progress \
    --checksum \
    --transfers 8 \
    --checkers 16 \
    --log-file /tmp/cnpg-pre-migration-${EXTERNAL_SERVER_NAME}.log
fi
```

**Expected Duration**:
- Small clusters (< 10GB): 30-60 minutes
- Medium clusters (10-50GB): 1-3 hours
- Large clusters (> 50GB): 3-6 hours

**Note**: This runs while the cluster operates normally. WAL archiving continues to Minio during this phase.

#### 0.2 Verify Pre-Sync Completion

```bash
# Compare file counts and sizes
echo "Minio ${SERVER_NAME}:"
rclone size minio-cnpg:cloudnative-pg/${SERVER_NAME}

echo "Garage ${SERVER_NAME}:"
rclone size garage:cloudnative-pg/${SERVER_NAME}

# If external server exists
if [ -n "${EXTERNAL_SERVER_NAME}" ]; then
  echo "Minio ${EXTERNAL_SERVER_NAME}:"
  rclone size minio-cnpg:cloudnative-pg/${EXTERNAL_SERVER_NAME}

  echo "Garage ${EXTERNAL_SERVER_NAME}:"
  rclone size garage:cloudnative-pg/${EXTERNAL_SERVER_NAME}
fi
```

**Success Criteria**: Garage shows similar total size to Minio (may differ slightly due to ongoing WAL archiving to Minio)

### Phase 1: Pre-Migration Preparation

**Timing**: Execute 2-24 hours before migration window

#### 1.1 Verify Current Backup Health

```bash
# Set cluster context
CLUSTER_NAME="mealie-16-db"
NAMESPACE="self-hosted"

# Check cluster status
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}

# Verify recent backups exist
kubectl get backup -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}

# Check WAL archiving status
kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.status.continuousArchiving}'
```

**Expected Output**:
- `continuousArchiving.lastSuccessfulTime`: Recent timestamp (< 10 minutes ago)
- At least one successful backup in last 24 hours

#### 1.2 Document Current Configuration

```bash
# Backup current manifests
mkdir -p /tmp/cnpg-migration-backup/${CLUSTER_NAME}

kubectl get objectstore -n ${NAMESPACE} -o yaml > \
  /tmp/cnpg-migration-backup/${CLUSTER_NAME}/objectstores-before.yaml

kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} -o yaml > \
  /tmp/cnpg-migration-backup/${CLUSTER_NAME}/cluster-before.yaml

kubectl get externalsecret -n ${NAMESPACE} -l app=${CLUSTER_NAME%%-16-db} -o yaml > \
  /tmp/cnpg-migration-backup/${CLUSTER_NAME}/externalsecrets-before.yaml
```

#### 1.3 Trigger Manual Backup

Force a fresh backup before migration:

```bash
# Create on-demand backup
kubectl cnpg backup ${CLUSTER_NAME} -n ${NAMESPACE} --backup-name ${CLUSTER_NAME}-pre-migration

# Wait for completion (may take 5-30 minutes depending on size)
kubectl wait --for=condition=completed \
  backup/${CLUSTER_NAME}-pre-migration \
  -n ${NAMESPACE} \
  --timeout=30m
```

### Phase 2: Migration Execution

**Timing**: Execute during low-activity window (e.g., 2-4 AM local time)

#### 2.1 Disable WAL Archiving (Temporary)

**For clusters WITH `isWALArchiver: true` only**:

Edit `kubernetes/base/apps/${NAMESPACE}/${APP}/db/pg-cluster-16.yaml`:

```yaml
# BEFORE
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true  # ← REMOVE THIS LINE TEMPORARILY
    parameters:
      barmanObjectName: mealie-backup-store
      serverName: mealie-16-v5
```

```yaml
# AFTER (temporary state)
plugins:
  - name: barman-cloud.cloudnative-pg.io
    # isWALArchiver: true  ← COMMENTED OUT
    parameters:
      barmanObjectName: mealie-backup-store
      serverName: mealie-16-v5
```

**WARNING**: Do NOT commit this change. Keep it uncommitted or in a temporary branch.

Apply the change:

```bash
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/pg-cluster-16.yaml
```

Verify WAL archiving stopped:

```bash
# Check logs for "WAL archiving disabled" or similar
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=50 | grep -i "wal\|archive"
```

#### 2.2 Delta Sync (Catch Up Since Phase 0)

**Purpose**: Synchronize only the new WAL segments and backups created since Phase 0 pre-sync.

**Execute on `cardinal` host**:

```bash
ssh cardinal.internal

# Set cluster-specific serverNames (same as Phase 0)
SERVER_NAME="mealie-16-v5"  # Adjust per cluster
EXTERNAL_SERVER_NAME="mealie-16-v4"  # Adjust per cluster (if applicable)

# Delta sync - only transfers files that changed since Phase 0
rclone sync \
  minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  garage:cloudnative-pg/${SERVER_NAME} \
  --progress \
  --checksum \
  --transfers 8 \
  --checkers 16 \
  --log-file /tmp/cnpg-delta-sync-${SERVER_NAME}.log

# If cluster has external recovery serverName, sync that too
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

**Verification**:

```bash
# Compare file counts and sizes
echo "Minio ${SERVER_NAME}:"
rclone size minio-cnpg:cloudnative-pg/${SERVER_NAME}

echo "Garage ${SERVER_NAME}:"
rclone size garage:cloudnative-pg/${SERVER_NAME}

# Sizes should match exactly (since WAL archiving is now paused)
```

**Expected Duration**: 1-5 minutes (only delta since Phase 0)

**Why This is Fast**: Since Phase 0 already transferred the bulk of the data (potentially hundreds of GB), this delta sync only needs to transfer:
- WAL segments created between Phase 0 and now (typically < 100MB)
- Any new backups created since Phase 0 (if scheduled backup ran)
- With WAL archiving paused, no new files are being created during sync

#### 2.3 Create New Garage Credentials ExternalSecret

Create `kubernetes/base/apps/${NAMESPACE}/${APP}/db/cnpg-garage-external-secret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cnpg-garage-access-mealie  # Adjust name per cluster
  namespace: self-hosted  # Adjust namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden-fields
  target:
    name: cnpg-garage-access-mealie  # Match metadata.name
    creationPolicy: Owner
    template:
      data:
        aws-access-key-id: "{{ .awsAccessKeyId }}"
        aws-secret-access-key: "{{ .awsSecretAccessKey }}"
        tls.crt: |
          -----BEGIN CERTIFICATE-----
          MIIBmDCCAT6gAwIBAgIRANSVoUiTXBGW9DkagKtQjWswCgYIKoZIzj0EAwIwKjEP
          MA0GA1UEChMGUHRpbmVtMRcwFQYDVQQDEw5QdGluZW0gUm9vdCBDQTAeFw0yNDAy
          MDkxMjUzMDBaFw0zNDAyMDYxMjUzMDBaMCoxDzANBgNVBAoTBlB0aW5lbTEXMBUG
          A1UEAxMOUHRpbmVtIFJvb3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS2
          kzW+UJV8eYmLOMDANrgnfprU5F2Epw7kmug6BlgU4g/Tm76FOMGRnfMdxf1B9J/P
          f0acYOYfYdWjs5wfnAlao0UwQzAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgw
          BgEB/wIBATAdBgNVHQ4EFgQUxsuM0fqHAbzj3aiCX44My6D6zg4wCgYIKoZIzj0E
          AwIDSAAwRQIgVM0UxJXuG4Vr/sKxlYv68QJezFpeOx/dtyCsqMJGrn4CIQD0BvL/
          7IGSXySSzaNnz+u9WmgdsM+ZM7z6bd5h4ZqBJg==
          -----END CERTIFICATE-----
  data:
    - secretKey: awsAccessKeyId
      remoteRef:
        key: <GARAGE_BITWARDEN_UUID>  # ← REPLACE with UUID from prerequisite #1
        property: AWS_ACCESS_KEY_ID
    - secretKey: awsSecretAccessKey
      remoteRef:
        key: <GARAGE_BITWARDEN_UUID>  # ← REPLACE with UUID from prerequisite #1
        property: AWS_SECRET_ACCESS_KEY
```

**Apply the new secret**:

```bash
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/cnpg-garage-external-secret.yaml

# Wait for ExternalSecret to sync
kubectl wait --for=condition=ready \
  externalsecret/cnpg-garage-access-mealie \
  -n ${NAMESPACE} \
  --timeout=2m

# Verify secret created
kubectl get secret cnpg-garage-access-mealie -n ${NAMESPACE}
```

#### 2.4 Update ObjectStore Resources (Atomic Switch)

**Update both ObjectStore files simultaneously**:

**File 1**: `objectstore-backup.yaml`

```yaml
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: mealie-backup-store
spec:
  configuration:
    destinationPath: s3://cloudnative-pg/
    endpointURL: https://s3.garage.internal  # ← CHANGED from s3.internal
    endpointCA:
      name: cnpg-garage-access-mealie  # ← CHANGED secret name
      key: tls.crt
    s3Credentials:
      accessKeyId:
        name: cnpg-garage-access-mealie  # ← CHANGED secret name
        key: aws-access-key-id
      secretAccessKey:
        name: cnpg-garage-access-mealie  # ← CHANGED secret name
        key: aws-secret-access-key
    data:
      compression: bzip2
    wal:
      compression: bzip2
      maxParallel: 8
  retentionPolicy: "30d"
```

**File 2** (if exists): `objectstore-external.yaml`

```yaml
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: mealie-external-store
spec:
  configuration:
    destinationPath: s3://cloudnative-pg/
    endpointURL: https://s3.garage.internal  # ← CHANGED from s3.internal
    endpointCA:
      name: cnpg-garage-access-mealie  # ← CHANGED secret name
      key: tls.crt
    s3Credentials:
      accessKeyId:
        name: cnpg-garage-access-mealie  # ← CHANGED secret name
        key: aws-access-key-id
      secretAccessKey:
        name: cnpg-garage-access-mealie  # ← CHANGED secret name
        key: aws-secret-access-key
    data:
      compression: bzip2
    wal:
      compression: bzip2
      maxParallel: 8
```

**Apply changes atomically**:

```bash
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/objectstore-backup.yaml
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/objectstore-external.yaml  # If exists
```

#### 2.5 Re-enable WAL Archiving

**Restore the `isWALArchiver: true` setting** in `pg-cluster-16.yaml`:

```yaml
# FINAL STATE
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true  # ← RESTORED
    parameters:
      barmanObjectName: mealie-backup-store
      serverName: mealie-16-v5
```

Apply:

```bash
kubectl apply -f kubernetes/base/apps/${NAMESPACE}/${APP}/db/pg-cluster-16.yaml
```

#### 2.6 Update kustomization.yaml

Add the new Garage ExternalSecret to the kustomization resources:

Edit `kubernetes/base/apps/${NAMESPACE}/${APP}/db/kustomization.yaml`:

```yaml
resources:
  - pg-cluster-16.yaml
  - objectstore-backup.yaml
  - objectstore-external.yaml  # If exists
  - scheduled-backup.yaml
  - cnpg-garage-external-secret.yaml  # ← ADD THIS
```

Apply kustomization:

```bash
kubectl apply -k kubernetes/base/apps/${NAMESPACE}/${APP}/db/
```

### Phase 3: Post-Migration Validation

**Timing**: Execute immediately after Phase 2 (within 10 minutes)

#### 3.1 Verify WAL Archiving Resumed

```bash
# Check cluster status
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}

# Verify WAL archiving to Garage
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=100 | grep -i "archive\|wal"

# Should see logs indicating WAL files being archived to s3.garage.internal
```

**Expected**: New WAL segments being archived within 5-10 minutes

#### 3.2 Trigger Test Backup to Garage

```bash
# Create test backup
kubectl cnpg backup ${CLUSTER_NAME} -n ${NAMESPACE} --backup-name ${CLUSTER_NAME}-post-migration-test

# Wait for completion
kubectl wait --for=condition=completed \
  backup/${CLUSTER_NAME}-post-migration-test \
  -n ${NAMESPACE} \
  --timeout=30m

# Verify backup succeeded
kubectl get backup ${CLUSTER_NAME}-post-migration-test -n ${NAMESPACE} -o yaml
```

**Expected**: Backup completes successfully, stored in Garage

#### 3.3 Verify Backup Data in Garage

```bash
# From cardinal host
ssh cardinal.internal

# List backups in Garage for this cluster
rclone ls garage:cloudnative-pg/${SERVER_NAME}/base/

# Should show:
# 1. Old backups (synced from Minio)
# 2. NEW backup (just created)
```

#### 3.4 Verify Recovery Capability (Optional but Recommended)

**WARNING**: This is a destructive test. Only perform on non-critical clusters or in test namespace.

Create a test recovery cluster pointing to Garage:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}-recovery-test
  namespace: ${NAMESPACE}
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-27

  storage:
    size: 5Gi
    storageClass: openebs-hostpath

  bootstrap:
    recovery:
      source: clusterBackup

  externalClusters:
    - name: clusterBackup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: mealie-backup-store  # Uses Garage ObjectStore
          serverName: mealie-16-v5
```

Apply and verify:

```bash
kubectl apply -f /tmp/recovery-test.yaml

# Watch recovery progress
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}-recovery-test -f

# Once recovered, verify data
kubectl exec -n ${NAMESPACE} ${CLUSTER_NAME}-recovery-test-1 -- psql -U postgres -c "SELECT count(*) FROM pg_database;"

# Clean up test cluster
kubectl delete cluster ${CLUSTER_NAME}-recovery-test -n ${NAMESPACE}
```

### Phase 4: Cleanup and Documentation

**Timing**: Execute 7 days after successful migration

#### 4.1 Remove Old Minio ExternalSecret

Once confident migration succeeded:

```bash
# Delete old Minio credentials
kubectl delete externalsecret cnpg-minio-access-mealie -n ${NAMESPACE}
kubectl delete secret cnpg-minio-access-mealie -n ${NAMESPACE}

# Remove from kustomization
# Edit kubernetes/base/apps/${NAMESPACE}/${APP}/db/kustomization.yaml
# Remove reference to cnpg-minio-external-secret.yaml
```

#### 4.2 Archive Minio Backup Data

**DO NOT delete Minio data immediately**. Archive for disaster recovery:

```bash
# From cardinal host
ssh cardinal.internal

# Create archive tarball
rclone sync minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  /srv/backups/cnpg-migration-archive/${SERVER_NAME}/ \
  --progress

# Compress
tar -czf /srv/backups/cnpg-migration-archive/${SERVER_NAME}.tar.gz \
  /srv/backups/cnpg-migration-archive/${SERVER_NAME}/

# Keep for 90 days before deletion
```

#### 4.3 Update Documentation

Update this document's cluster table to mark migration complete:

```markdown
| 1 | **mealie-16-db** ✅ | self-hosted | ... | **Migrated: 2026-01-XX** |
```

Commit all changes to git:

```bash
git add kubernetes/base/apps/${NAMESPACE}/${APP}/db/
git commit -m "feat(cnpg): migrate ${CLUSTER_NAME} backups to Garage S3

- Update ObjectStore resources to point to s3.garage.internal
- Create new Garage credentials ExternalSecret
- Verified backup and WAL archiving working on Garage
- Old Minio data archived on cardinal:/srv/backups/

Ref: docs/plans/cnpg-minio-to-garage-migration.md"
```

## Cluster-Specific Notes

### mealie-16-db (First Migration)

- **Namespace**: self-hosted
- **Server Name**: mealie-16-v5
- **External Server**: mealie-16-v4
- **Has isWALArchiver**: Yes
- **Activity Level**: Low (recipe management app)
- **Special Considerations**: None
- **Files to modify**:
  - `objectstore-backup.yaml` ✓
  - `objectstore-external.yaml` ✓
  - `cnpg-garage-external-secret.yaml` (create new)
  - `kustomization.yaml` (add new secret)

### wger-16-db

- **Namespace**: self-hosted
- **Server Name**: wger-16-v1
- **External Server**: N/A (no recovery source)
- **Has isWALArchiver**: Yes
- **Activity Level**: Low
- **Special Considerations**: No externalClusters block
- **Files to modify**:
  - `objectstore-backup.yaml` ✓
  - `cnpg-garage-external-secret.yaml` (create new)
  - `kustomization.yaml` (add new secret)

### wallabag-16-db

- **Namespace**: self-hosted
- **Server Name**: wallabag-16-v5
- **External Server**: wallabag-16-v4
- **Has isWALArchiver**: No (check manifest!)
- **Activity Level**: Low-Medium (article saving)
- **Special Considerations**: Standard migration

### miniflux-16-db

- **Namespace**: self-hosted
- **Server Name**: miniflux-16-v5
- **External Server**: miniflux-16-v4
- **Has isWALArchiver**: No (check manifest!)
- **Activity Level**: Medium (RSS reader, periodic updates)
- **Special Considerations**: Standard migration

### wikijs-16-db

- **Namespace**: self-hosted
- **Server Name**: wikijs-16-v5
- **External Server**: wikijs-16-v4 (incomplete in listing - verify!)
- **Has isWALArchiver**: No (check manifest!)
- **Activity Level**: Low-Medium (wiki edits)
- **Special Considerations**: Standard migration

### hass-16-db

- **Namespace**: home-automation
- **Server Name**: hass-16-v4
- **External Server**: hass-16-v3
- **Has isWALArchiver**: Yes
- **Activity Level**: High (continuous sensor data)
- **Special Considerations**:
  - 10Gi storage (larger than others)
  - High write volume (consider longer sync time)
  - Migrate during lowest activity (3-5 AM)

### immich-16-db

- **Namespace**: media
- **Server Name**: immich-16-db
- **External Server**: N/A (no recovery source)
- **Has isWALArchiver**: Yes
- **Activity Level**: High (photo uploads/processing)
- **Special Considerations**:
  - Uses custom image: `tensorchord/cloudnative-vectorchord:16-0.4.3`
  - 10Gi storage
  - Highest data volume
  - Migrate last
  - Consider longer maintenance window

## Rollback Procedure

If migration fails or issues detected:

### Immediate Rollback (Within Migration Window)

**Step 1**: Revert ObjectStore resources to Minio

```bash
# Restore from backup
kubectl apply -f /tmp/cnpg-migration-backup/${CLUSTER_NAME}/objectstores-before.yaml
```

**Step 2**: Verify WAL archiving resumed to Minio

```bash
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=50 | grep -i archive
```

**Step 3**: Delete Garage ExternalSecret

```bash
kubectl delete externalsecret cnpg-garage-access-${APP} -n ${NAMESPACE}
```

### Post-Migration Rollback (After Validation)

**Scenario**: Issues discovered hours/days after migration

**Step 1**: Verify Minio data still intact

```bash
ssh cardinal.internal
rclone ls minio-cnpg:cloudnative-pg/${SERVER_NAME}/base/
```

**Step 2**: Follow immediate rollback steps above

**Step 3**: Re-sync any WAL segments archived to Garage back to Minio

```bash
# Sync Garage → Minio (reverse direction)
rclone sync \
  garage:cloudnative-pg/${SERVER_NAME} \
  minio-cnpg:cloudnative-pg/${SERVER_NAME} \
  --progress \
  --checksum
```

## Risk Assessment

### High Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Data loss during sync | **CRITICAL** | Very Low | Use `--checksum`, verify before/after, retain Minio data for 90 days |
| Credentials misconfiguration | Medium | Medium | Test Garage access in Phase 0, verify ExternalSecret before migration |
| Network interruption during delta sync | Medium | Very Low | Run sync on `cardinal` (local network), use `--log-file`, bulk already transferred in Phase 0 |

**Note on WAL Archiving Gap Risk**: Originally assessed as "High Risk", but with 3-pod HA configuration, this risk is effectively **eliminated** for routine failures:
- All clusters have 3 replicas with streaming replication
- Pod crashes, node failures, even 2-pod failures are handled by automatic promotion with zero data loss
- WAL archiving gap only matters for total cluster destruction (all 3 pods + volumes lost simultaneously)
- Pre-migration backup (Phase 1.3) provides recovery point for this datacenter-level disaster scenario
- Likelihood of total cluster loss during 15-30 minute window: **Extremely Low**

### Medium Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| ObjectStore update not atomic | Medium | Medium | Apply both files in quick succession, verify immediately |
| Barman plugin fails to connect to Garage | Medium | Low | Test with manual barman-cloud commands pre-migration |
| Retention policy not applied | Low | Medium | Explicitly set in ObjectStore spec |

### Low Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| CA certificate mismatch | Low | Very Low | Same step-ca infrastructure for both endpoints |
| Backup performance degradation | Low | Low | Monitor backup duration post-migration |

## Success Criteria

Migration considered successful when ALL criteria met:

- [ ] Phase 0 pre-sync completed with 0 errors, checksums verified
- [ ] Phase 2 delta sync completed with 0 errors, Minio and Garage sizes match exactly
- [ ] New WAL segments archived to Garage within 15 minutes of re-enabling
- [ ] Test backup completed successfully to Garage
- [ ] Cluster status shows `continuousArchiving: true` and healthy
- [ ] No error logs related to backup/archiving for 24 hours
- [ ] (Optional) Recovery test from Garage backup succeeded
- [ ] Git commit with changes pushed to main branch
- [ ] Documentation updated

## Timeline Estimate (Per Cluster)

| Phase | Duration | Notes |
|-------|----------|-------|
| **Phase 0: Pre-sync (bulk)** | **30 min - 6 hours** | **Run days before; varies by cluster size (< 10GB: 30-60min, > 50GB: 3-6hrs)** |
| Phase 1: Pre-migration prep | 30 min | Backups, documentation, health checks |
| Phase 2.1: WAL archiving disable | 2 min | Manifest edit + apply |
| **Phase 2.2: Delta sync** | **1-5 min** | **Fast! Only transfers delta since Phase 0** |
| Phase 2.3: Create Garage secret | 5 min | ExternalSecret manifest + verify sync |
| Phase 2.4: Update ObjectStores | 5 min | Manifest edits + apply |
| Phase 2.5: Re-enable WAL archiving | 2 min | Manifest edit + apply |
| Phase 2.6: Update kustomization | 2 min | Add new secret reference |
| Phase 3: Validation | 30-45 min | Backups, logs, tests |
| **Migration Window Total** | **45-60 min** | **Actual switchover time (Phases 1-3)** |
| **Actual WAL Gap** | **15-30 min** | **Phase 2.1 through 2.5 (3-pod HA protects)** |

**Key Insight**: With Phase 0 pre-sync strategy, the actual migration window is **< 1 hour** per cluster, with WAL archiving gap of only **15-30 minutes** (safely covered by 3-pod HA).

**Full migration (7 clusters)**:
- **Phase 0 pre-syncs**: Can run in parallel for multiple clusters (limited by cardinal host resources)
- **Migration windows**: 1 cluster per session, spread over 2-4 weeks
- **Total hands-on time**: ~7 hours (7 clusters × 1 hour each)

## References

### Documentation

- [Barman Cloud Plugin Usage Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)
- [Barman Cloud Plugin Migration Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/)
- [Barman Cloud Plugin Object Stores](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/)
- [CloudNative-PG WAL Archiving](https://cloudnative-pg.io/documentation/preview/wal_archiving/)

### Internal Documentation

- `CLAUDE.md` - Infrastructure overview
- `docs/architecture/network/tailscale-architecture.md` - Network access patterns
- Issue #31 - Original migration request

### Related Issues/PRs

- (To be filled as migration progresses)

## Appendix A: Verification Commands Cheat Sheet

```bash
# Set variables for cluster
export CLUSTER_NAME="mealie-16-db"
export NAMESPACE="self-hosted"
export APP="mealie"
export SERVER_NAME="mealie-16-v5"

# Check cluster health
kubectl cnpg status ${CLUSTER_NAME} -n ${NAMESPACE}

# Check WAL archiving status
kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.status.continuousArchiving}'

# View recent backup jobs
kubectl get backup -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}

# Check ObjectStore resources
kubectl get objectstore -n ${NAMESPACE}

# Verify ExternalSecret synced
kubectl get externalsecret -n ${NAMESPACE} | grep garage

# View cluster logs
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=100

# Grep for errors
kubectl logs -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} --tail=500 | grep -i error

# Check backup in Garage (from cardinal)
ssh cardinal.internal "rclone ls garage:cloudnative-pg/${SERVER_NAME}/base/"
```

## Appendix B: Template Files

### Template: cnpg-garage-external-secret.yaml

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cnpg-garage-access-APPNAME  # ← REPLACE
  namespace: NAMESPACE  # ← REPLACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden-fields
  target:
    name: cnpg-garage-access-APPNAME  # ← REPLACE (match metadata.name)
    creationPolicy: Owner
    template:
      data:
        aws-access-key-id: "{{ .awsAccessKeyId }}"
        aws-secret-access-key: "{{ .awsSecretAccessKey }}"
        tls.crt: |
          -----BEGIN CERTIFICATE-----
          MIIBmDCCAT6gAwIBAgIRANSVoUiTXBGW9DkagKtQjWswCgYIKoZIzj0EAwIwKjEP
          MA0GA1UEChMGUHRpbmVtMRcwFQYDVQQDEw5QdGluZW0gUm9vdCBDQTAeFw0yNDAy
          MDkxMjUzMDBaFw0zNDAyMDYxMjUzMDBaMCoxDzANBgNVBAoTBlB0aW5lbTEXMBUG
          A1UEAxMOUHRpbmVtIFJvb3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS2
          kzW+UJV8eYmLOMDANrgnfprU5F2Epw7kmug6BlgU4g/Tm76FOMGRnfMdxf1B9J/P
          f0acYOYfYdWjs5wfnAlao0UwQzAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgw
          BgEB/wIBATAdBgNVHQ4EFgQUxsuM0fqHAbzj3aiCX44My6D6zg4wCgYIKoZIzj0E
          AwIDSAAwRQIgVM0UxJXuG4Vr/sKxlYv68QJezFpeOx/dtyCsqMJGrn4CIQD0BvL/
          7IGSXySSzaNnz+u9WmgdsM+ZM7z6bd5h4ZqBJg==
          -----END CERTIFICATE-----
  data:
    - secretKey: awsAccessKeyId
      remoteRef:
        key: GARAGE_BITWARDEN_UUID  # ← REPLACE
        property: AWS_ACCESS_KEY_ID
    - secretKey: awsSecretAccessKey
      remoteRef:
        key: GARAGE_BITWARDEN_UUID  # ← REPLACE
        property: AWS_SECRET_ACCESS_KEY
```

### Template: objectstore-backup.yaml (Garage)

```yaml
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: APPNAME-backup-store  # ← REPLACE
spec:
  configuration:
    destinationPath: s3://cloudnative-pg/
    endpointURL: https://s3.garage.internal
    endpointCA:
      name: cnpg-garage-access-APPNAME  # ← REPLACE
      key: tls.crt
    s3Credentials:
      accessKeyId:
        name: cnpg-garage-access-APPNAME  # ← REPLACE
        key: aws-access-key-id
      secretAccessKey:
        name: cnpg-garage-access-APPNAME  # ← REPLACE
        key: aws-secret-access-key
    data:
      compression: bzip2
    wal:
      compression: bzip2
      maxParallel: 8
  retentionPolicy: "30d"
```

---

**END OF DOCUMENT**
