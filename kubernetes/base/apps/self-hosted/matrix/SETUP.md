# Matrix (Synapse + Element Web) Setup Guide

This guide covers the prerequisites for deploying Matrix Synapse and Element Web on the K3s cluster.

## Architecture

- **Synapse** — Matrix homeserver at `https://matrix.internal`
- **Element Web** — Web client at `https://element.internal`
- **CNPG PostgreSQL** — 3-instance cluster on OPI 5+ nodes
- **VolSync** — Media store backup to Garage S3
- **Kanidm OIDC** — SSO authentication (no local accounts)
- **Federation disabled** — private internal server only

## Prerequisites

### 1. Create Kanidm OIDC Client

On `mysecrets.internal` as `idm_admin`:

```bash
kanidm system oauth2 create synapse "Matrix Synapse" https://matrix.internal
kanidm system oauth2 add-redirect-url synapse https://matrix.internal/_synapse/client/oidc/callback
kanidm system oauth2 update-scope-map synapse idm_all_persons openid profile email
kanidm system oauth2 show-basic-secret synapse
```

Save the client secret from the last command.

### 2. Generate Synapse Secrets

**Registration shared secret:**
```bash
openssl rand -hex 32
```

**Signing key (via Docker):**
```bash
docker run --rm -v /tmp/synapse-keys:/data \
  -e SYNAPSE_SERVER_NAME=matrix.internal \
  -e SYNAPSE_REPORT_STATS=no \
  ghcr.io/element-hq/synapse:v1.148.0 generate
cat /tmp/synapse-keys/matrix.internal.signing.key
rm -rf /tmp/synapse-keys
```

This outputs a line like `ed25519 a_xxxx <base64>` — that's the full signing key value.

### 3. Create Bitwarden Items

Create two items in Vaultwarden:

**Item: "Synapse OIDC"** — Custom fields:
| Field | Type | Value |
|---|---|---|
| `client_id` | Text | `synapse` |
| `client_secret` | Hidden | *(from step 1)* |

**Item: "Synapse Secrets"** — Custom fields:
| Field | Type | Value |
|---|---|---|
| `REGISTRATION_SECRET` | Hidden | *(from step 2 — hex string)* |
| `SIGNING_KEY` | Hidden | *(from step 2 — `ed25519 a_xxxx ...`)* |

### 4. Update Manifest UUIDs

After creating the Bitwarden items, get their UUIDs (from the browser URL or `bw` CLI) and update:

| File | Field | UUID Source |
|---|---|---|
| `oidc-external-secret.yaml` | `remoteRef.key` (both entries) | Synapse OIDC item |
| `secrets-external-secret.yaml` | `remoteRef.key` (both entries) | Synapse Secrets item |

The VolSync Bitwarden key in `matrix-app.yaml` uses the shared VolSync credentials item (same as kanboard, esphome, etc.).

## Verification

After ArgoCD syncs:

```bash
# ArgoCD app status
argocd app get matrix

# CNPG cluster health (expect 3/3 ready)
kubectl -n self-hosted get cluster synapse-16-db

# Synapse API responding
curl -k https://matrix.internal/_synapse/client/versions

# Element Web loads
curl -k -o /dev/null -w '%{http_code}' https://element.internal
```

## Post-Deploy

### Promote Admin User

After your first OIDC login through Element, promote yourself to Synapse admin:

```bash
# Get an access token (visible in Element: Settings → Help & About → Access Token)
curl -k -X PUT "https://matrix.internal/_synapse/admin/v1/users/@nicolas:matrix.internal" \
  -H "Authorization: Bearer <your-access-token>" \
  -H "Content-Type: application/json" \
  -d '{"admin": true}'
```

### Register Bot Accounts (Optional)

Use the registration shared secret to create accounts without OIDC:

```bash
# From a pod with network access, or via ingress
register_new_matrix_user -k <REGISTRATION_SECRET> \
  -u botname -p <password> --no-admin \
  https://matrix.internal
```

## Troubleshooting

### Synapse Won't Start

**Check logs:**
```bash
kubectl -n self-hosted logs deployment/synapse
```

**Common issues:**
- Database not ready — wait for CNPG cluster to be healthy
- Signing key format wrong — must be full `ed25519 a_xxxx <base64>` line
- OIDC secret mismatch — verify Kanidm secret matches Bitwarden item

### OIDC Login Fails

**"SSL certificate problem" or OIDC discovery failure:**
- Synapse uses `skip_verification: true` in homeserver.yaml for Kanidm's private CA
- Verify the CA ConfigMap is mounted at `/etc/ssl/custom/ca.crt`

**"User not found" after redirect:**
- Ensure `idm_all_persons` scope map is set on the Kanidm client
- Check Kanidm user has `email` and `displayname` attributes set

### ExternalSecret Not Syncing

```bash
kubectl -n self-hosted get externalsecret
kubectl -n self-hosted describe externalsecret synapse-oidc
```

- Verify Bitwarden item UUIDs match the manifests
- Check field names are exact (case-sensitive)
