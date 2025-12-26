# Flux to ArgoCD Secret Migration Summary

**Created**: 2025-12-26
**Context**: Migration of 6 Flux apps to ArgoCD requires migrating from SOPS to Bitwarden

## Secret Audit Results

### Apps Requiring VolSync Secrets (4 apps)

All 4 apps use VolSync for backups to Garage S3 at `s3.internal`:

| App | Namespace | Restic Repository | S3 Credentials | Restic Password |
|-----|-----------|-------------------|----------------|-----------------|
| esphome | home-automation | `s3:https://s3.internal/volsync-volumes/esphome` | **Shared** | Unique |
| mqtt | home-automation | `s3:https://s3.internal/volsync-volumes/mqtt` | **Shared** | Unique |
| archivebox | media | `s3:https://s3.internal/volsync-volumes/archivebox` | **Shared** | Unique |
| kanboard | self-hosted | `s3:https://s3.internal/volsync-volumes/kanboard` | **Shared** | Unique |

**Shared S3 Credentials**:
- AWS_ACCESS_KEY_ID: `BziXxDiyknGH8cEbZdwq`
- AWS_SECRET_ACCESS_KEY: (same for all)
- CA Certificate: Ptinem Root CA (same for all)

**Unique Per App**:
- RESTIC_REPOSITORY: Different path for each app
- RESTIC_PASSWORD: Unique encryption password for each app

### Apps Without VolSync (2 apps)

| App | Namespace | Secrets | Notes |
|-----|-----------|---------|-------|
| zwave | home-automation | None | Static PV, no secrets needed |
| home-assistant | home-automation | Certificate only | Uses cert-manager for TLS cert |

## Migration Strategy

### Option 1: Individual Bitwarden Items (Recommended for ArgoCD Pattern)

Create **4 separate Bitwarden items**, one per app, each containing all VolSync credentials:

**Pros**:
- Follows ArgoCD VolSync component pattern exactly
- Each app is self-contained
- Easier to manage permissions per app
- Consistent with existing ArgoCD apps

**Cons**:
- S3 credentials duplicated 4 times
- More Bitwarden items to manage

**Implementation**:
```
Bitwarden Item: "k8s-volsync-esphome"
├─ RESTIC_REPOSITORY: s3:https://s3.internal/volsync-volumes/esphome
├─ RESTIC_PASSWORD: <unique-esphome-password>
├─ AWS_ACCESS_KEY_ID: BziXxDiyknGH8cEbZdwq
└─ AWS_SECRET_ACCESS_KEY: <shared-secret>

Bitwarden Item: "k8s-volsync-mqtt"
├─ RESTIC_REPOSITORY: s3:https://s3.internal/volsync-volumes/mqtt
├─ RESTIC_PASSWORD: <unique-mqtt-password>
├─ AWS_ACCESS_KEY_ID: BziXxDiyknGH8cEbZdwq
└─ AWS_SECRET_ACCESS_KEY: <shared-secret>

(Same for archivebox and kanboard)
```

**CA Certificate**: Stored in ConfigMap (not secret) per ArgoCD VolSync component pattern

### Option 2: Shared + Individual Items

Create **1 shared item + 4 app items**:

**Pros**:
- No duplication of S3 credentials
- Easier to rotate S3 credentials (one place)

**Cons**:
- Requires customizing ArgoCD VolSync component
- More complex ExternalSecret configurations
- Deviates from standard pattern

**Not Recommended** - adds complexity without significant benefit

## Recommended Approach: Option 1

### Step 1: Extract Secrets from SOPS

```bash
# esphome
sops -d kubernetes/kubernetes/main/apps/home-automation/esphome/app/volume/local/secrets.sops.yaml > /tmp/esphome-secrets.yaml

# archivebox
sops -d kubernetes/kubernetes/main/apps/media/archivebox/app/volsync/local/secrets.sops.yaml > /tmp/archivebox-secrets.yaml

# kanboard
sops -d kubernetes/kubernetes/main/apps/self-hosted/kanboard/app/volsync/local/secrets.sops.yaml > /tmp/kanboard-secrets.yaml

# mqtt (from cluster secret)
kubectl get secret -n home-automation mqtt-volsync-secret -o jsonpath='{.data}' | jq -r 'to_entries[] | "\(.key)=\(.value | @base64d)"' > /tmp/mqtt-secrets.txt
```

### Step 2: Create Bitwarden Items

Using Bitwarden CLI or Web UI, create 4 items:

1. **k8s-volsync-esphome** (in `kubernetes` folder, tagged `volsync`)
   - Custom Fields:
     - RESTIC_REPOSITORY (text)
     - RESTIC_PASSWORD (password)
     - AWS_ACCESS_KEY_ID (text)
     - AWS_SECRET_ACCESS_KEY (password)

2. **k8s-volsync-mqtt** (same structure)

3. **k8s-volsync-archivebox** (same structure)

4. **k8s-volsync-kanboard** (same structure)

### Step 3: Get Bitwarden UUIDs

```bash
# Login to Bitwarden CLI
bw login

# Get item UUIDs
bw list items --search "k8s-volsync-esphome" | jq -r '.[0].id'
bw list items --search "k8s-volsync-mqtt" | jq -r '.[0].id'
bw list items --search "k8s-volsync-archivebox" | jq -r '.[0].id'
bw list items --search "k8s-volsync-kanboard" | jq -r '.[0].id'
```

### Step 4: Create CA ConfigMap

Create `kubernetes/base/apps/home-automation/esphome/volsync-ca-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: esphome-volsync-ca
  namespace: home-automation
data:
  ca.crt: |
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
```

(Repeat for mqtt, archivebox, kanboard)

### Step 5: Update ArgoCD App Kustomizations

Each app will use the VolSync component. Example for esphome:

```yaml
# kubernetes/base/apps/home-automation/esphome/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: home-automation
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - volsync-ca-configmap.yaml
components:
  - ../../../components/volsync
configMapGenerator:
  - name: esphome-config
    literals:
      - BITWARDEN_KEY=<uuid-from-step-3>
      - STORAGE_CLASS=longhorn
      - STORAGE_CAPACITY=100Mi
      - CACHE_CAPACITY=100Mi
      - BACKUP_SCHEDULE=0 */6 * * *  # 6-hour schedule
namePrefix: esphome-
```

## Verification Steps

After migration, verify each app:

### 1. Check ExternalSecret Sync

```bash
kubectl get externalsecret -n home-automation esphome-volsync-secret
kubectl describe externalsecret -n home-automation esphome-volsync-secret
```

### 2. Check Secret Creation

```bash
kubectl get secret -n home-automation esphome-volsync-secret
kubectl get secret -n home-automation esphome-volsync-secret -o jsonpath='{.data}' | jq 'keys'
```

Should show: `["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_PASSWORD", "RESTIC_REPOSITORY"]`

### 3. Check VolSync ReplicationSource

```bash
kubectl get replicationsource -n home-automation esphome
kubectl describe replicationsource -n home-automation esphome
```

### 4. Trigger Test Backup

```bash
kubectl annotate replicationsource -n home-automation esphome volsync.backube/trigger-sync="test-$(date +%s)" --overwrite
```

### 5. Verify Backup Completed

```bash
kubectl get replicationsource -n home-automation esphome -o jsonpath='{.status.lastSyncTime}'
```

## Rollback Procedure

If Bitwarden migration fails for an app:

1. **Keep Flux running** - don't suspend Flux Kustomization yet
2. **Delete ArgoCD app** (keep resources):
   ```bash
   argocd app delete esphome --cascade=false
   ```
3. **Flux will continue** managing the app with SOPS secrets

## Post-Migration Cleanup

After all apps successfully migrated and stable for 1+ week:

1. **Delete SOPS secret files** (archive first):
   ```bash
   git mv kubernetes/kubernetes/main/apps/home-automation/esphome/app/volume/local/secrets.sops.yaml \
          kubernetes/archive/flux-legacy/esphome-volsync-secrets.sops.yaml
   ```

2. **Remove from .sops.yaml** if no longer needed

3. **Document Bitwarden items** in password manager for team

## CA Certificate Notes

**Ptinem Root CA** is the public certificate for Garage S3 at `s3.internal`:
- Valid until: 2034-02-06
- Used for TLS verification when connecting to Garage S3
- **Public certificate** (not secret) - OK to store in ConfigMaps
- Shared by all VolSync apps

If S3 certificate changes, update all 4 ConfigMaps.

## Security Considerations

1. **Bitwarden Access**: Ensure ExternalSecrets operator has access to Bitwarden vault
2. **Secret Rotation**: Rotate Restic passwords periodically (requires re-encrypting backups)
3. **S3 Credentials**: Rotate S3 credentials requires updating all 4 Bitwarden items
4. **CA Certificate**: Monitor expiry (2034), but not urgent

## Next Steps

1. ✅ Complete secret audit
2. ⏳ Create Bitwarden items (manual step)
3. ⏳ Get Bitwarden UUIDs
4. ⏳ Create CA ConfigMaps for each app
5. ⏳ Update ArgoCD app kustomizations with VolSync component
6. ⏳ Test with kanboard first (lowest risk)
7. ⏳ Proceed with remaining apps

---

**Status**: Secret audit complete, ready for Bitwarden migration
**Blocked on**: Manual Bitwarden item creation
