# Tailscale Kubernetes Operator

Enables Kubernetes pods to join the Tailscale network and use exit nodes for IP masking.

## Prerequisites

1. **Tailscale Account** with admin access
2. **Bitwarden** access to store OAuth credentials
3. **External Secrets Operator** deployed in cluster

## Setup Instructions

### 1. Configure Tailscale ACL Tags

Go to https://login.tailscale.com/admin/acls and add these tags:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  }
}
```

- `tag:k8s-operator` - For the operator itself
- `tag:k8s` - For pods created by the operator (owned by the operator)

### 2. Create OAuth Client

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "Generate OAuth client"
3. Configure:
   - **Description:** `Kubernetes Operator`
   - **Scopes:**
     - ✅ Devices (Write)
     - ✅ Auth keys (Write)
   - **Tags:** `tag:k8s-operator`
4. Click "Generate client"
5. **Save the Client ID and Client Secret** (you won't see the secret again!)

### 3. Store Credentials in Bitwarden

1. Log in to Bitwarden
2. Create a new item:
   - **Name:** `Tailscale Operator`
   - **Type:** Login or Secure Note
3. Add custom fields:
   - Field name: `TAILSCALE_OAUTH_CLIENT_ID`
   - Value: (paste the OAuth Client ID)
   - Field name: `TAILSCALE_OAUTH_CLIENT_SECRET`
   - Value: (paste the OAuth Client Secret)
4. Save the item and **copy its UUID** from the URL or item details

### 4. Update ExternalSecret

Edit `oauth-secret-es.yaml` and replace `REPLACE_WITH_BITWARDEN_ITEM_UUID` with your Bitwarden item UUID:

```bash
# Edit the file
vim kubernetes/base/infra/network/tailscale-operator/oauth-secret-es.yaml

# Replace both occurrences of REPLACE_WITH_BITWARDEN_ITEM_UUID
# with your actual Bitwarden item UUID
```

### 5. Deploy the Operator

The operator is managed by ArgoCD and will deploy automatically once the OAuth secret is configured:

```bash
# Apply the ArgoCD application
kubectl apply -f kubernetes/base/infra/network/tailscale-operator-app.yaml

# Watch the deployment
kubectl get pods -n network -l app=tailscale-operator -w

# Check operator logs
kubectl logs -n network -l app=tailscale-operator -f
```

### 6. Verify Deployment

Check that the operator registered in your Tailscale admin console:

1. Go to https://login.tailscale.com/admin/machines
2. Look for a machine named `tailscale-operator` with tag `tag:k8s-operator`
3. The machine should show as "Connected"

## Using the Operator

### Connect a Pod to Tailscale

Add annotations to your pod to connect it to Tailscale:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  annotations:
    tailscale.com/proxy: "true"  # Enable Tailscale for this pod
    tailscale.com/tags: "tag:k8s"  # Tags to apply
spec:
  # ... your pod spec
```

### Use Exit Node

To route pod traffic through the Tailscale exit node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: irc-bot
  annotations:
    tailscale.com/proxy: "true"
    tailscale.com/tags: "tag:k8s"
    tailscale.com/use-exit-node: "tailscale-exit"  # Name of your exit node
spec:
  # ... your pod spec
```

The pod's traffic will now exit through the VPS, hiding your home IP.

## Troubleshooting

### Operator pod not starting

```bash
# Check operator logs
kubectl logs -n network -l app=tailscale-operator

# Check if OAuth secret exists
kubectl get secret operator-oauth -n network

# Check ExternalSecret status
kubectl describe externalsecret tailscale-operator-oauth -n network
```

### OAuth secret not created

```bash
# Check ExternalSecret
kubectl describe externalsecret tailscale-operator-oauth -n network

# Verify Bitwarden connection
kubectl get clustersecretstore bitwarden-fields -o yaml

# Check External Secrets Operator logs
kubectl logs -n security -l app.kubernetes.io/name=external-secrets -f
```

### Operator not appearing in Tailscale admin

1. Check operator logs for authentication errors
2. Verify OAuth client has correct scopes (Devices + Auth Keys write)
3. Verify OAuth client is tagged with `tag:k8s-operator`
4. Check that ACL tags are configured correctly

## Configuration

### Helm Values

See `helm-values.yaml` for configuration options:
- **operatorConfig.logging** - Log level (info, debug)
- **operatorConfig.defaultTags** - Default tags for all devices
- **resources** - Resource requests/limits for operator pod

### Security

The operator runs with:
- Non-root user (UID 1000)
- Read-only root filesystem
- Dropped capabilities
- No privilege escalation

## Documentation

- Tailscale Operator Docs: https://tailscale.com/kb/1236/kubernetes-operator
- Exit Nodes: https://tailscale.com/kb/1103/exit-nodes
- External Secrets: https://external-secrets.io/
