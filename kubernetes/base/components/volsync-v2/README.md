# VolSync Component v2

A reusable Kustomize component for VolSync backup/restore with ArgoCD.

## Features

- **Variable substitution**: Uses ArgoCD CMP plugin (`kustomize-envsubst`) for clean variable handling
- **No orphaned PVCs**: Uses `cleanupTempPVC: true` and `cleanupCachePVC: true`
- **Bootstrap-once pattern**: ArgoCD `CreateOnly=true` prevents re-triggering restores
- **On-demand re-restore**: Delete the ReplicationDestination to trigger a new restore
- **Sensible defaults**: Only required variables are `APP`, `VOLSYNC_CAPACITY`, and `VOLSYNC_BITWARDEN_KEY`

## How It Works

### First Deployment (Bootstrap)

1. ArgoCD creates ReplicationDestination (bootstrap)
2. VolSync restores data from S3 backup to a snapshot
3. PVC is created with `dataSourceRef` pointing to the snapshot
4. Kubernetes clones the snapshot data into the PVC
5. VolSync cleans up temporary/cache PVCs
6. ReplicationSource starts scheduled backups

### Subsequent Deployments

1. ArgoCD sees ReplicationDestination exists → skips (CreateOnly)
2. PVC already exists → no action
3. ReplicationSource continues scheduled backups

### Manual Re-Restore

1. Delete the ReplicationDestination: `kubectl delete replicationdestination myapp-dst -n myns`
2. ArgoCD recreates it → triggers new restore
3. **Note**: You may need to delete and recreate the PVC to pick up new data

## Usage

### 1. Create the ArgoCD Application with CMP plugin

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    path: kubernetes/base/apps/self-hosted/myapp
    repoURL: 'https://forge.internal/nemo/avalanche.git'
    targetRevision: HEAD
    plugin:
      name: kustomize-envsubst
      env:
        # Required variables
        - name: APP
          value: myapp
        - name: VOLSYNC_CAPACITY
          value: 5Gi
        - name: VOLSYNC_BITWARDEN_KEY
          value: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        # Optional variables (defaults shown)
        - name: VOLSYNC_STORAGECLASS
          value: longhorn
        - name: VOLSYNC_ACCESSMODE
          value: ReadWriteOnce
        - name: VOLSYNC_CACHE_CAPACITY
          value: 2Gi
        - name: VOLSYNC_SCHEDULE
          value: "0 * * * *"
        - name: VOLSYNC_UID
          value: "1000"
        - name: VOLSYNC_GID
          value: "1000"
  destination:
    namespace: myapp
    name: 'in-cluster'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2. Add the component to your app's kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  # Don't add a PVC here - it comes from the component

components:
  - ../../../components/volsync-v2

# Override CA certificate for S3 endpoint
patches:
  - target:
      kind: ConfigMap
      name: .*-volsync-ca
    patch: |
      - op: replace
        path: /data/ca.crt
        value: |
          -----BEGIN CERTIFICATE-----
          <your CA certificate here>
          -----END CERTIFICATE-----
```

### 3. Reference the PVC in your deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      containers:
        - name: myapp
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: myapp  # Same as APP variable
```

## Configuration Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `APP` | Application name (used for all resource names and S3 path) | - | Yes |
| `VOLSYNC_CAPACITY` | PVC and restore capacity | - | Yes |
| `VOLSYNC_BITWARDEN_KEY` | Bitwarden item UUID for S3 credentials | - | Yes |
| `VOLSYNC_STORAGECLASS` | Storage class for PVCs | `longhorn` | No |
| `VOLSYNC_ACCESSMODE` | PVC access mode | `ReadWriteOnce` | No |
| `VOLSYNC_CACHE_CAPACITY` | Cache PVC capacity | `2Gi` | No |
| `VOLSYNC_SCHEDULE` | Backup cron schedule | `0 * * * *` | No |
| `VOLSYNC_UID` | Mover container UID | `1000` | No |
| `VOLSYNC_GID` | Mover container GID | `1000` | No |

## Bitwarden Secret Structure

The Bitwarden item (referenced by `VOLSYNC_BITWARDEN_KEY`) should have these custom fields:

- `RESTIC_PASSWORD`: Password for restic repository encryption
- `AWS_ACCESS_KEY_ID`: S3 access key
- `AWS_SECRET_ACCESS_KEY`: S3 secret key

## Resource Naming

With `APP=myapp`, the component creates:

| Resource | Name |
|----------|------|
| PVC | `myapp` |
| ReplicationSource | `myapp` |
| ReplicationDestination | `myapp-dst` |
| ExternalSecret | `myapp-volsync-secret` |
| Secret (created by ES) | `myapp-volsync-secret` |
| ConfigMap (CA) | `myapp-volsync-ca` |

## Migration from v1/ctest Pattern

1. Ensure you have a recent backup in S3
2. Update the ArgoCD Application to use the `kustomize-envsubst` plugin with env vars
3. Remove the old kustomize `replacements` and `configMapGenerator` from your app
4. Remove `namePrefix` if you were using it (APP variable now controls naming)
5. Add the v2 component and simplify your kustomization
6. Delete the old ReplicationDestination and PVC if needed
7. Sync with ArgoCD - it will restore from backup and create new resources

## Triggering a Manual Restore

```bash
# Delete the ReplicationDestination to trigger re-restore
kubectl delete replicationdestination myapp-dst -n myns

# If needed, also delete and let ArgoCD recreate the PVC
kubectl delete pvc myapp -n myns

# Sync with ArgoCD (or wait for auto-sync)
argocd app sync myapp
```
