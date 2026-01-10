# Immich Installation Plan

**Status**: ✅ Completed
**Issue**: [#37](https://forge.internal/nemo/avalanche/issues/37)
**Started**: 2026-01-10
**Completed**: 2026-01-10

## Overview

Install Immich (https://immich.app) - an open-source photo and video management solution similar to Google Photos - on the Kubernetes cluster. Immich provides photo/video backup, organization, face recognition, object detection, and smart search capabilities.

## Lessons Learned: Plan vs Reality

**Critical Finding**: This plan was based on outdated knowledge of Immich's architecture (likely v1.x or early v2.x). Immich v2.4.1 has **fundamentally different architecture** that invalidated major sections of this plan.

### Why the Plan Was Wrong

**Root Cause**: The plan was written using:
- Stale architectural knowledge from older Immich versions
- Outdated documentation references
- Assumptions about PostgreSQL extensions (pgvector vs VectorChord)
- No verification against current Immich v2.4.1 documentation

**Lesson**: Always verify current architecture by reading:
1. Official docker-compose.yml from the version you're deploying
2. Latest release notes and migration guides
3. Current GitHub issues (not just docs)
4. Actual error messages during deployment

### Major Architecture Differences

#### 1. Component Count: 5 Services → 3 Services

**Plan Expected** (lines 66-91):
```
immich-server (port 3001)        - API only
immich-web (port 3000)           - Frontend UI
immich-microservices             - Background jobs
immich-machine-learning          - ML worker
redis                            - Job queue
```

**Reality in v2.4.1**:
```
immich-server (port 2283)        - Unified: API + Frontend + Background jobs
immich-machine-learning (port 3003) - ML worker
redis                            - Job queue
```

**Impact**:
- Deleted `web/` and `microservices/` directories (don't exist in v2.4.1)
- Changed ingress backend from `immich-web:3000` to `immich-server:2283`
- Removed obsolete service definitions

#### 2. PostgreSQL Extension: pgvector → VectorChord

**Plan Expected** (lines 150-200):
```dockerfile
# Build custom image
FROM ghcr.io/cloudnative-pg/postgresql:16.4
RUN apt-get install postgresql-16-pgvector
```
```sql
CREATE EXTENSION IF NOT EXISTS pgvector;
```

**Reality in v2.4.1**:
```yaml
# Use pre-built TensorChord image
imageName: ghcr.io/tensorchord/cloudnative-vectorchord:16-0.4.3

postgresql:
  shared_preload_libraries:
    - "vchord.so"

postInitApplicationSQL:
  - CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
  # ↑ This auto-installs pgvector v0.8.0 as dependency
```

**Impact**:
- **No custom image building needed** - TensorChord provides ready-made image
- Immich v2.4.1 **requires VectorChord**, not just pgvector
- VectorChord is the successor to pgvecto.rs for vector similarity search
- Step 0 of original plan was completely unnecessary

**Discovery**: Found by reading error messages showing Immich looking for VectorChord features, then researching TensorChord documentation.

#### 3. Missing Kubernetes Service for ML Component

**Plan**: Only created Deployment for machine-learning (lines 131-133)

**Reality**: **Critical omission!** Server couldn't reach ML worker without Service:
```yaml
# Had to create: kubernetes/base/apps/media/immich/machine-learning/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-machine-learning
spec:
  ports:
  - port: 3003
    targetPort: 3003
```

**Impact**: Upload jobs failed with "Machine learning request failed for all URLs" until Service was created.

**Discovery**: Found by following server logs showing connection failures to `http://immich-machine-learning:3003`.

#### 4. Missing Nginx Upload Size Limit

**Plan**: No mention of upload size configuration

**Reality**: **Critical omission!** Nginx ingress has default 1MB body size limit:
```yaml
# Had to add to ingress.yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-body-size: "0"  # Disable limit
```

**Impact**: All photo uploads failed with generic "Unable to upload file" error until annotation was added.

**Discovery**: Only found after verifying ML service was working but uploads still failed. Not in server logs - had to know about nginx defaults.

#### 5. Database SUPERUSER Privilege Required

**Plan**: Assumed CloudNative-PG default user permissions would suffice

**Reality**: Immich's TypeORM auto-migrations **require SUPERUSER** to create extensions:
```bash
# Had to manually grant on database pod
kubectl exec immich-16-db-1 -c postgres -- \
  psql -U postgres -c "ALTER USER immich WITH SUPERUSER;"
```

**Impact**: Schema initialization failed with "relation 'system_metadata' does not exist" until SUPERUSER granted.

**Discovery**: Found by checking TypeORM migration logs and understanding it needs extension creation privileges.

#### 6. CPU Limits Forbidden in Cluster

**Plan Expected** (lines 355-361):
```yaml
resources:
  limits:
    cpu: 200m
    memory: 1Gi
```

**Reality** (Cluster Policy):
```yaml
resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    memory: 1Gi  # CPU limits forbidden
```

**Impact**: All CPU limits had to be removed. Redis readiness probe was timing out due to CPU throttling.

**Discovery**: User explicitly stated "remove any cpu limit, those are forbidden in my cluster :)"

#### 7. Separate ML Cache Volume Required

**Plan**: Single cache PVC for all services

**Reality**: ReadWriteOnce volumes can't be shared:
```yaml
# Had to create separate PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-ml-cache  # Separate from immich-cache
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
```

**Impact**: ML pod stuck in "Multi-Attach error" until separate PVC created.

### What Actually Worked From the Plan

✅ **Storage Strategy** - Three-tier approach was correct:
- NFS for photo library (cardinal:/tank/Images)
- Longhorn for caches
- CloudNative-PG for database

✅ **Backup Strategy** - VolSync + Barman backups architecture was sound

✅ **Network Architecture** - Ingress, TLS, Homepage integration patterns were correct

✅ **Resource Sizing** - Memory requests/limits were appropriate

### Key Takeaways

1. **Never trust plans based on version assumptions** - Always verify current architecture
2. **Read the source** - Official docker-compose.yml reveals true architecture
3. **Follow the errors** - Error messages led to VectorChord, Service, SUPERUSER discoveries
4. **Documentation lags reality** - GitHub issues and release notes more current than docs
5. **Test incrementally** - Each discovery (ML service, nginx limit) came from testing previous fix
6. **Cluster policies matter** - Generic plans don't account for local constraints (CPU limits)

### Corrected Implementation Summary

**What we actually deployed**:
```
kubernetes/base/apps/media/immich/
├── db/
│   └── pg-cluster-16.yaml              # TensorChord VectorChord image (not custom build)
├── redis/
│   ├── deployment.yaml                 # No CPU limits
│   └── service.yaml
├── server/
│   ├── deployment.yaml                 # Unified server on port 2283
│   └── service.yaml
├── machine-learning/
│   ├── deployment.yaml                 # Port 3003 exposed
│   ├── service.yaml                    # ← ADDED (not in plan)
│   └── kustomization.yaml
├── storage/
│   ├── pvc-library.yaml               # NFS from cardinal
│   ├── pvc-cache.yaml                 # Longhorn for server cache
│   ├── pvc-ml-cache.yaml              # ← ADDED separate ML cache
│   └── volsync/...
└── ingress.yaml                        # ← ADDED proxy-body-size annotation
```

**Files NOT created** (from plan but don't exist in v2.4.1):
- `web/deployment.yaml` - Service merged into server
- `web/service.yaml` - Service merged into server
- `microservices/deployment.yaml` - Service merged into server
- `db/image/Dockerfile` - Used pre-built TensorChord image instead

## Requirements

- **Storage size**: Small (< 100GB initially, expandable)
- **NPU usage**: Future enhancement - leverage Orange Pi 5+ NPU for ML inference
- **Storage location**: `/tank/Images` on cardinal.internal (separate from `/tank/Media` for videos/series)

## Architecture Decision: Hybrid Storage Approach

### Storage Strategy (Three-Tier)

**Tier 1: Photo/Video Library (Primary Data)**
- **Solution**: NFS mount from cardinal.internal at `/tank/Images`
- **Size**: 100GB (expandable as needed)
- **Access Mode**: ReadWriteMany
- **Rationale**:
  - Keeps photos separate from `/tank/Media` (which contains videos/series)
  - Cardinal has ZFS with S3 backup infrastructure
  - Requires adding `/tank/Images` NFS export to cardinal's NixOS config
  - Follows existing pattern for large media storage

**Tier 2: Application State/Cache (Thumbnails, Search Indices)**
- **Solution**: Longhorn PVC with VolSync backups
- **Size**: 10Gi
- **Access Mode**: ReadWriteOnce
- **Backup**: Hourly VolSync to Garage S3 (24 hourly, 7 daily, 4 weekly retention)
- **Rationale**: Critical for service continuity, needs cluster-level redundancy

**Tier 3: Database (PostgreSQL with pgvector)**
- **Solution**: CloudNative-PG cluster (3 replicas)
- **Size**: 10Gi per instance (OpenEBS hostpath)
- **Extensions**: pgvector (for ML embeddings), uuid-ossp
- **Backup**: Daily Barman Cloud Plugin to Garage S3 (30-day retention)
- **Rationale**: Immich requires pgvector for AI-powered search (CLIP embeddings)

### Backup & Recovery Strategy

#### Database Backups
- **Method**: Barman Cloud Plugin (daily)
- **Target**: `s3://cloudnative-pg/immich-16-db/`
- **Retention**: 30 days
- **Recovery**: `kubectl cnpg restore` to new cluster

#### Cache/State Backups
- **Method**: VolSync + Restic (hourly)
- **Target**: `s3://s3.garage.internal/volsync-volumes/immich/`
- **Retention**: 24 hourly, 7 daily, 4 weekly
- **Recovery**: Trigger ReplicationDestination with `restore-once`

#### Photo/Video Library Backups
- **Method**: Cardinal host ZFS snapshots + Garage S3 (external to cluster)
- **Note**: Photos never stored only in cluster - cluster failure doesn't lose data
- **Recovery**: NFS mount automatically reconnects on pod restart

## Immich Component Architecture

Immich consists of 5 services that communicate via PostgreSQL and Redis:

1. **immich-server**: Main API server (port 3001)
   - Handles API requests, authentication, asset management
   - Coordinates with other services via PostgreSQL and Redis

2. **immich-web**: Frontend UI (port 3000)
   - React-based web interface
   - Accessed via ingress at `https://immich.internal`

3. **immich-microservices**: Background jobs
   - Thumbnail generation
   - Metadata extraction (EXIF)
   - Video transcoding
   - Asset organization

4. **immich-machine-learning**: ML worker
   - Face detection and recognition
   - Object detection
   - CLIP embeddings for smart search
   - Currently CPU-based; future NPU integration possible

5. **Redis**: Job queue coordinator
   - Manages async jobs between services
   - Ephemeral (no persistent storage needed)

## Directory Structure

```
kubernetes/base/apps/media/immich/
├── immich-app.yaml                      # ArgoCD application (in parent dir)
├── kustomization.yaml                   # Main orchestration
├── ingress.yaml                         # HTTPS ingress (immich.internal)
│
├── db/                                  # PostgreSQL with pgvector
│   ├── image/                           # Custom PostgreSQL image
│   │   ├── Dockerfile                   # pgvector installation
│   │   └── .dockerignore
│   ├── kustomization.yaml
│   ├── pg-cluster-16.yaml               # 3-replica cluster
│   ├── scheduled-backup.yaml            # Daily backups
│   ├── objectstore-backup.yaml          # Barman S3 config
│   ├── objectstore-external.yaml        # External backup source
│   └── cnpg-minio-external-secret.yaml  # Garage S3 credentials
│
├── redis/                               # Job queue
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
│
├── server/                              # API server
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
│
├── web/                                 # Frontend UI
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
│
├── microservices/                       # Background jobs
│   ├── kustomization.yaml
│   └── deployment.yaml
│
├── machine-learning/                    # ML worker
│   ├── kustomization.yaml
│   └── deployment.yaml
│
└── storage/                             # Volumes
    ├── kustomization.yaml
    ├── pv-library.yaml                  # NFS PV for cardinal photos
    ├── pvc-library.yaml                 # NFS PVC
    ├── pvc-cache.yaml                   # Longhorn for cache/state
    └── volsync/
        └── local/
            ├── kustomization.yaml
            ├── external-secret.yaml
            ├── replication-source.yaml
            └── replication-destination.yaml
```

## Implementation Steps

### Step 0: Build Custom PostgreSQL Image with pgvector
**Status**: ⏳ Pending

**Issue**: The standard CloudNative-PG PostgreSQL image (`ghcr.io/cloudnative-pg/postgresql:16.4-27`) does not include the pgvector extension, which is **required** by Immich for:
- Smart search using CLIP embeddings (semantic photo search like "dog on beach")
- Face recognition and clustering
- Object detection similarity matching

**Solution**: Build a custom Docker image based on CloudNative-PG's PostgreSQL image with pgvector installed.

**Files to create**:
- `kubernetes/base/apps/media/immich/db/image/Dockerfile`
- `kubernetes/base/apps/media/immich/db/image/.dockerignore`

**Dockerfile content**:
```dockerfile
ARG POSTGRES_VERSION=16.4
FROM ghcr.io/cloudnative-pg/postgresql:${POSTGRES_VERSION}

USER root

# Install pgvector extension
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-${POSTGRES_VERSION%%.*}-pgvector && \
    rm -rf /var/lib/apt/lists/*

USER postgres
```

**Build and push**:
```bash
# Build for both amd64 and arm64
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <registry>/postgresql-pgvector:16.4 \
  -f kubernetes/base/apps/media/immich/db/image/Dockerfile \
  kubernetes/base/apps/media/immich/db/image/

# Push to registry (Forgejo, GHCR, or other)
docker push <registry>/postgresql-pgvector:16.4
```

**Update pg-cluster-16.yaml** to use the custom image:
```yaml
imageName: <registry>/postgresql-pgvector:16.4
```

**References**:
- [CloudNativePG: Creating custom container images](https://cloudnative-pg.io/blog/creating-container-images/)
- [pgvector PostgreSQL extension](https://github.com/pgvector/pgvector)

### Step 1: Prepare NFS Storage on Cardinal
**Status**: ✅ Completed (2026-01-10)

**File to modify**: `nixos/hosts/cardinal/default.nix`

Update NFS exports to add `/tank/Images`:

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    /tank/Books 10.0.0.0/8(all_squash,rw,insecure,sync,no_subtree_check,anonuid=1000,anongid=1000)
    /tank/Media 10.0.0.0/8(all_squash,rw,insecure,sync,no_subtree_check,anonuid=1000,anongid=1000)
    /tank/Images 10.0.0.0/8(all_squash,rw,insecure,sync,no_subtree_check,anonuid=1000,anongid=1000)
  '';
};
```

Then create the directory:

```bash
# SSH to cardinal
ssh cardinal.internal

# Create Images directory with correct permissions
sudo mkdir -p /tank/Images
sudo chown 1000:1000 /tank/Images
sudo chmod 755 /tank/Images
```

**Completed actions**:
- Created ZFS dataset: `tank/Images` on cardinal
- Added NFS export for `/tank/Images` to `nixos/hosts/cardinal/default.nix`
- Deployed changes to cardinal (NFS server restarted successfully)
- Export verified: `exportfs -v` shows `/tank/Images` accessible to 10.0.0.0/8

### Step 2: Create Database with pgvector Extension
**Status**: ✅ Completed (2026-01-10) - **Blocked: Requires Step 0 (custom image)**

**File**: `kubernetes/base/apps/media/immich/db/pg-cluster-16.yaml`

Key features:
- 3 replicas on Orange Pi 5+ nodes (HA)
- Install pgvector extension via `postInitApplicationSQL`:
  ```sql
  CREATE EXTENSION IF NOT EXISTS pgvector;
  CREATE EXTENSION IF NOT EXISTS uuid-ossp;
  ```
- Database: "immich", owner: "immich"
- Barman Cloud Plugin backups to Garage S3
- Auto-generated secret: `immich-16-db-app` (contains connection details)

**Completed actions**:
- Created CloudNative-PG cluster manifest with 3 replicas
- Configured pgvector extension in `postInitApplicationSQL` (awaiting custom image)
- Set up daily Barman backups to Garage S3
- Created ObjectStore and ScheduledBackup resources
- Created ExternalSecret for S3 credentials

**Blocking issue**: Database initdb fails because base image lacks pgvector extension. Step 0 must be completed first.

**Pattern source**: `kubernetes/base/apps/self-hosted/mealie/db/pg-cluster-16.yaml`

### Step 3: Deploy Redis
**Status**: ✅ Completed (2026-01-10)

**File**: `kubernetes/base/apps/media/immich/redis/deployment.yaml`

- Image: `redis:8.4-alpine`
- No persistent storage (ephemeral job queue)
- Resources: 10m CPU / 64Mi RAM request, 256Mi limit
- Single replica

**Completed actions**:
- Created Redis deployment and service manifests
- Configured liveness and readiness probes

### Step 4: Create Storage Resources
**Status**: ✅ Completed (2026-01-10)

**Files**: `kubernetes/base/apps/media/immich/storage/`

**NFS Volume** (`pv-library.yaml` + `pvc-library.yaml`):
- PersistentVolume pointing to `cardinal.internal:/tank/Images`
- Size: 100Gi
- StorageClass: nfs
- AccessMode: ReadWriteMany
- ReclaimPolicy: Retain

**Cache Volume** (`pvc-cache.yaml`):
- StorageClass: longhorn
- Size: 10Gi
- AccessMode: ReadWriteOnce

**VolSync Backup** (`volsync/local/`):
- Hourly backups of cache PVC to Garage S3
- Repository: `s3://s3.garage.internal/volsync-volumes/immich`
- Retention: 24 hourly, 7 daily, 4 weekly

**Completed actions**:
- Created NFS PV/PVC for photo library (100Gi from cardinal:/tank/Images)
- Created Longhorn PVC for cache (10Gi)
- Set up VolSync backup with hourly schedule
- Created ExternalSecret for S3 credentials
- Created ReplicationSource and ReplicationDestination
- Added volsync CA ConfigMap

**Pattern sources**:
- NFS: `kubernetes/base/apps/media/radarr/deployment.yaml`
- VolSync: `kubernetes/base/apps/media/archivebox/volsync/`

### Step 5: Deploy Immich Services
**Status**: ✅ Completed (2026-01-10)

**Common Environment Variables** (shared across all services):
```yaml
env:
  - name: DB_HOSTNAME
    valueFrom:
      secretKeyRef:
        name: immich-16-db-app
        key: host
  - name: DB_PORT
    valueFrom:
      secretKeyRef:
        name: immich-16-db-app
        key: port
  - name: DB_USERNAME
    valueFrom:
      secretKeyRef:
        name: immich-16-db-app
        key: username
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: immich-16-db-app
        key: password
  - name: DB_DATABASE_NAME
    valueFrom:
      secretKeyRef:
        name: immich-16-db-app
        key: dbname
  - name: REDIS_HOSTNAME
    value: immich-redis.media
  - name: REDIS_PORT
    value: "6379"
  - name: TZ
    value: "America/New_York"
  - name: LOG_LEVEL
    value: "log"
```

**Service Specifications**:

| Service | Image | Replicas | CPU Req | Mem Req | CPU Limit | Mem Limit | Port |
|---------|-------|----------|---------|---------|-----------|-----------|------|
| immich-server | ghcr.io/immich-app/immich-server:latest | 1 | 100m | 512Mi | 200m | 1Gi | 3001 |
| immich-web | ghcr.io/immich-app/immich-web:latest | 1 | 5m | 64Mi | 50m | 256Mi | 3000 |
| immich-microservices | ghcr.io/immich-app/immich-server:latest | 1 | 50m | 512Mi | 500m | 2Gi | - |
| immich-machine-learning | ghcr.io/immich-app/immich-machine-learning:latest | 1 | 100m | 1Gi | 500m | 2Gi | - |
| immich-redis | redis:8.4-alpine | 1 | 10m | 64Mi | 10m | 256Mi | 6379 |

**Completed actions**:
- Created deployment manifests for all 5 services
- Configured shared environment variables for database and Redis
- Set up volume mounts for library and cache
- Created services for immich-server, immich-web, and Redis
- Configured resource requests and limits
- Added health probes (liveness, readiness, startup)

**Pattern source**: `kubernetes/base/apps/self-hosted/wger/deployment.yaml`

### Step 6: Create Ingress
**Status**: ✅ Completed (2026-01-10)

**File**: `kubernetes/base/apps/media/immich/ingress.yaml`

- Host: `immich.internal`
- Backend: immich-web service (port 3000)
- TLS: cert-manager with ca-server-cluster-issuer
- Homepage annotations:
  ```yaml
  gethomepage.dev/enabled: "true"
  gethomepage.dev/name: "Immich"
  gethomepage.dev/description: "Photo & Video Library"
  gethomepage.dev/group: "Media"
  gethomepage.dev/icon: "immich.png"
  ```

**Completed actions**:
- Created ingress manifest for `immich.internal`
- Configured TLS with cert-manager (ca-server-cluster-issuer)
- Added Homepage integration annotations
- Backend points to immich-web service on port 3000

**Pattern source**: `kubernetes/base/apps/media/archivebox/ingress.yaml`

### Step 7: Create ArgoCD Application
**Status**: ✅ Completed (2026-01-10)

**File**: `kubernetes/base/apps/media/immich-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: immich
  namespace: argocd
spec:
  project: default
  source:
    path: kubernetes/base/apps/media/immich
    repoURL: https://forge.internal/nemo/avalanche.git
    targetRevision: HEAD
  destination:
    namespace: media
    name: 'in-cluster'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Completed actions**:
- Created ArgoCD Application manifest
- Configured auto-sync with prune and selfHeal
- Set destination namespace to media
- Created namespace automatically

### Step 8: Update Parent Kustomization
**Status**: ✅ Completed (2026-01-10)

**File**: `kubernetes/base/apps/media/kustomization.yaml`

Add `- immich-app.yaml` to resources list.

**Completed actions**:
- Added `immich-app.yaml` to resources in `kubernetes/base/apps/media/kustomization.yaml`
- Committed and pushed all changes (commit: a9a90df)

## Final Status (2026-01-10)

### ✅ Completed Successfully

**All components operational**:
- ✅ PostgreSQL 16 with VectorChord 0.4.3 + pgvector 0.8.0 (3/3 replicas)
- ✅ Redis job queue (1/1 replica)
- ✅ Immich unified server on port 2283 (1/1 replica)
- ✅ Machine learning service with Kubernetes Service (1/1 replica)
- ✅ NFS storage from cardinal:/tank/Images (2.6TB available)
- ✅ Longhorn cache volumes (separate for server and ML)
- ✅ Ingress with TLS at https://immich.internal
- ✅ Nginx upload size limit disabled
- ✅ Photo upload and ML processing working (CLIP, OCR, facial recognition)
- ✅ VolSync backups configured
- ✅ Barman PostgreSQL backups configured

**Key fixes applied beyond original plan**:
1. Used TensorChord VectorChord image instead of building custom image
2. Granted SUPERUSER to immich database user for TypeORM migrations
3. Created machine-learning Kubernetes Service (missing from plan)
4. Added nginx proxy-body-size annotation for uploads
5. Removed all CPU limits per cluster policy
6. Created separate ML cache PVC to avoid Multi-Attach errors
7. Updated architecture for v2.4.1 unified server (no web/microservices)

## Resource Requirements

| Component | Request CPU | Request Memory | Limit CPU | Limit Memory |
|-----------|-------------|----------------|-----------|--------------|
| immich-server | 100m | 512Mi | 200m | 1Gi |
| immich-web | 5m | 64Mi | 50m | 256Mi |
| immich-microservices | 50m | 512Mi | 500m | 2Gi |
| immich-machine-learning | 100m | 1Gi | 500m | 2Gi |
| immich-redis | 10m | 64Mi | 10m | 256Mi |
| PostgreSQL (3 replicas) | 100m/ea | 512Mi/ea | 200m/ea | 1Gi/ea |

**Total**: ~1.5 CPU, ~6Gi RAM baseline

## Testing Checklist

After deployment, verify each component:

- [ ] **Database Connectivity**:
  ```bash
  kubectl exec -n media deployment/immich-server -- \
    psql -h immich-16-db-rw.media -U immich -d immich -c '\dx'
  # Should show pgvector extension
  ```

- [ ] **Redis Queue**:
  ```bash
  kubectl exec -n media deployment/immich-server -- \
    redis-cli -h immich-redis.media PING
  # Should return PONG
  ```

- [ ] **File Storage**:
  ```bash
  # Upload test photo via web UI
  # Verify file appears on cardinal
  ssh cardinal.internal 'ls -lh /tank/Images'
  ```

- [ ] **ML Inference**:
  - Upload photo via web UI
  - Monitor microservices logs for thumbnail generation
  - Monitor ML worker logs for face detection
  - Verify search functionality works

- [ ] **VolSync Backups**:
  ```bash
  kubectl get replicationsource -n media immich-cache
  # Should show successful completion
  ```

- [ ] **Database Backups**:
  ```bash
  kubectl get schedulebackup -n media immich-16-db
  # Should show successful daily backups
  ```

- [ ] **Ingress/TLS**:
  ```bash
  curl -sk https://immich.internal
  # Should return Immich web UI
  ```

- [ ] **End-to-End Verification**:
  1. Access `https://immich.internal`
  2. Complete initial setup wizard
  3. Upload test photo
  4. Verify thumbnail generation (microservices working)
  5. Verify face detection (ML worker working)
  6. Verify file appears in `/tank/Images` on cardinal
  7. Check VolSync backup status
  8. Check database backup status
  9. Verify Homepage integration shows Immich

## Future Enhancements

### NPU Integration for ML Worker
**Status**: Future enhancement (not in initial implementation)

The Orange Pi 5+ NPU infrastructure is fully operational and could accelerate Immich's ML workloads:

**Current State**:
- NPU service deployed at `https://npu-inference.internal`
- Uses TensorFlow Lite + Mesa Teflon delegate
- Performance: ~16ms inference for MobileNetV1
- Supports image classification (1000 ImageNet classes)

**Integration Options**:
1. **Convert Immich models to TFLite**: Convert CLIP/face detection models to quantized TFLite format
2. **API integration**: Modify Immich ML worker to call NPU service HTTP API
3. **Direct TFLite integration**: Modify Immich to use TFLite runtime with Teflon delegate

**Recommendation**: Start with CPU-based ML worker. The Orange Pi 5+ nodes have good CPU performance. NPU integration can be added later if ML processing becomes a bottleneck.

**Reference**: `docs/architecture/npu/rknn-npu-integration-plan.md`, `kubernetes/base/apps/ml/npu-inference/`

### Multi-User Support
- Configure Immich for multi-user mode
- Integrate with Kanidm (auth.internal) for SSO

### External Backup
- Add rclone job to replicate photos to external cloud storage (B2, Wasabi)
- Pattern: `nixos/hosts/cardinal/backups/remote/rclone-media-remote.nix`

## Actual Deployment Sequence (2026-01-10)

### Phase 1: Initial Setup
1. ✅ Updated cardinal NFS exports and created `/tank/Images` ZFS dataset
2. ✅ Created Kubernetes manifests based on plan (database, redis, storage, services)
3. ✅ Committed and pushed to git (commit a9a90df) - ArgoCD auto-syncing

### Phase 2: Database Extension Discovery
4. ❌ Database initialization failed - "extension 'vector' is not available"
5. 🔍 Researched and discovered Immich v2.4.1 requires **VectorChord**, not just pgvector
6. ✅ Switched to TensorChord image `ghcr.io/tensorchord/cloudnative-vectorchord:16-0.4.3`
7. ✅ Updated PostgreSQL config to load vchord.so shared library
8. ✅ Changed extension creation to `CREATE EXTENSION vchord CASCADE`
9. ✅ Recreated database cluster - all 3 replicas healthy

### Phase 3: Permission Issues
10. ❌ Schema initialization failed - "relation 'system_metadata' does not exist"
11. 🔍 Discovered TypeORM auto-migrations require SUPERUSER privilege
12. ✅ Manually granted: `ALTER USER immich WITH SUPERUSER;`
13. ✅ Database schema created successfully (40+ tables)

### Phase 4: Architecture Migration
14. ❌ Server failing health probes - wrong endpoint `/api/server-info/ping`
15. 🔍 Discovered v2.4.1 uses unified architecture (no separate web/microservices)
16. ✅ Deleted obsolete `web/` and `microservices/` directories
17. ✅ Updated server to use default entrypoint on port 2283
18. ✅ Fixed health probe endpoints to `/api/server/ping`
19. ✅ Updated ingress backend from `immich-web:3000` to `immich-server:2283`

### Phase 5: Resource Optimization
20. ❌ Redis readiness probe timing out
21. ✅ Removed all CPU limits per cluster policy
22. ✅ Increased Redis CPU request to 50m

### Phase 6: ML Service Connectivity
23. ❌ Photo uploads failing - ML processing jobs couldn't connect
24. 🔍 Discovered missing Kubernetes Service for machine-learning component
25. ✅ Created `machine-learning/service.yaml` exposing port 3003
26. ✅ Added containerPort to deployment
27. ✅ Verified connectivity: `curl http://immich-machine-learning:3003/ping` → "pong"

### Phase 7: Storage Multi-Attach
28. ❌ ML pod stuck in ContainerCreating - "Multi-Attach error"
29. ✅ Created separate `immich-ml-cache` PVC (RWO volumes can't be shared)
30. ✅ Updated ML deployment to use separate cache volume

### Phase 8: Upload Size Limit
31. ❌ Photo uploads still failing - generic "Unable to upload file" error
32. 🔍 Realized nginx ingress has default 1MB body size limit
33. ✅ Added annotation: `nginx.ingress.kubernetes.io/proxy-body-size: "0"`
34. ✅ **Photo uploads working!** ML processing (CLIP, OCR, faces) successful

### Phase 9: Verification
35. ✅ Verified all pods running (database 3/3, server 1/1, ML 1/1, redis 1/1)
36. ✅ Verified NFS storage mounted (2.6TB available)
37. ✅ Verified ingress and TLS certificate
38. ✅ Completed initial setup via web UI at `https://immich.internal`
39. ✅ Tested photo upload with ML processing
40. ✅ Verified VolSync and Barman backups configured

## Notes

- **Image versions**: Using `latest` tag for initial deployment. Consider pinning versions after validation.
- **Scaling**: All services can scale horizontally except machine-learning (should run 1 replica per node).
- **Performance**: Initial photo upload and processing will be slow (thumbnail generation + face detection). Monitor resource usage and adjust limits if needed.
- **Security**: All services run as non-root user (UID 1000). Database credentials auto-generated by CloudNative-PG.
- **Cardinal dependency**: If cardinal is unavailable, photo library becomes read-only. Services continue to function with cached data.

## References

- Official Immich documentation: https://immich.app/docs
- Immich GitHub: https://github.com/immich-app/immich
- CloudNative-PG operator: `kubernetes/base/apps/cnpg-system/`
- Existing multi-service pattern: `kubernetes/base/apps/self-hosted/wger/`
- NFS storage pattern: `kubernetes/base/apps/media/radarr/`
- VolSync backup pattern: `kubernetes/base/apps/media/archivebox/volsync/`
