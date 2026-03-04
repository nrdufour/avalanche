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
curl -k https://matrix.internal/_matrix/client/versions

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

## Design Decisions & Gotchas

These are important notes for anyone modifying this deployment.

### Secret Injection via Init Container

Synapse does **not** support environment variable interpolation in `homeserver.yaml` (the `%(ENV)s` syntax seen in some docs is only for `generate` mode Jinja2 templates). Secrets are injected at runtime using an init container that runs a Python script to replace `__PLACEHOLDER__` tokens in the ConfigMap template with actual secret values.

The `__VAR__` placeholder format (e.g. `__SYNAPSE_DB_PASSWORD__`) is deliberate — the CMP `kustomize-envsubst` plugin processes all manifests including ConfigMaps, so `${VAR}` and `$${VAR}` syntax both get mangled by `envsubst`. The double-underscore format is invisible to `envsubst`.

### x_forwarded for Reverse Proxy

Synapse's listener must have `x_forwarded: true` when behind a TLS-terminating reverse proxy (nginx ingress). Without it, Synapse sees all requests as HTTP and redirects to HTTPS, causing an infinite redirect loop on SSO login. The setting makes Synapse trust the `X-Forwarded-Proto` header from nginx.

### SSL_CERT_FILE for OIDC Discovery

Synapse's Twisted HTTP client needs `SSL_CERT_FILE=/etc/ssl/custom/ca.crt` to trust the Ptinem Root CA when connecting to `auth.internal` for OIDC metadata discovery. The `skip_verification` config option only affects OIDC token verification, not the underlying TLS connection.

### UID 0 (Run as Root)

The Synapse image uses `gosu` to drop to UID 991, but that UID has no `/etc/passwd` entry. This causes `libpq` to fail with `local user with ID 991 does not exist` when connecting to PostgreSQL. Setting `UID=0` and `GID=0` env vars tells the entrypoint to skip the `gosu` call.

### Recreate Deployment Strategy

The media PVC is `ReadWriteOnce`, so the default `RollingUpdate` strategy causes `Multi-Attach` errors during rollouts (old pod holds the volume, new pod can't mount it). `Recreate` kills the old pod first.

### Element Web enableServiceLinks

Kubernetes auto-injects env vars for every service in the namespace (e.g. `ELEMENT_WEB_SERVICE_HOST`, `ELEMENT_WEB_PORT`). The Element Web nginx image uses `${ELEMENT_WEB_PORT}` in its config template — the K8s-injected value (`tcp://10.x.x.x:80`) overwrites the intended default (`80`), breaking nginx. `enableServiceLinks: false` prevents K8s from injecting these vars.

### CNPG Locale

The CNPG cluster uses `localeCollate: "C"` and `localeCType: "C"` — Synapse requires C locale for correct text sorting in PostgreSQL.

## Troubleshooting

### Synapse Won't Start

**Check logs:**
```bash
kubectl -n self-hosted logs deployment/synapse
kubectl -n self-hosted logs deployment/synapse -c render-config  # init container
```

**Common issues:**
- Database not ready — wait for CNPG cluster to be healthy
- Signing key format wrong — must be full `ed25519 a_xxxx <base64>` line
- OIDC secret mismatch — verify Kanidm secret matches Bitwarden item
- Init container failed — check `render-config` logs for Python errors

### OIDC Login Fails

**OIDC discovery timeout during startup:**
- Synapse does a blocking OIDC metadata fetch on startup
- Verify `SSL_CERT_FILE` env var is set and CA ConfigMap is mounted
- Test from pod: `wget --no-check-certificate -O- https://auth.internal/oauth2/openid/synapse/.well-known/openid-configuration`

**"User not found" after redirect:**
- Ensure `idm_all_persons` scope map is set on the Kanidm client
- Check Kanidm user has `email` and `displayname` attributes set

### Config Not Updating After Change

The homeserver.yaml is rendered by an init container from a ConfigMap. After changing `homeserver-configmap.yaml`:
1. ArgoCD must sync the new ConfigMap
2. The pod must restart to re-run the init container
3. If using `subPath` mounts, a pod restart is always needed (no live reload)

Force it with: `kubectl -n self-hosted rollout restart deployment/synapse`

### ExternalSecret Not Syncing

```bash
kubectl -n self-hosted get externalsecret
kubectl -n self-hosted describe externalsecret synapse-oidc
```

- Verify Bitwarden item UUIDs match the manifests
- Check field names are exact (case-sensitive)
