# muninn — Hermes Matrix Bot Setup

How to provision (or re-provision) a Matrix bot account for `hermes-agent`
running on muninn so you can chat with it from Element on your phone/laptop.

## Prerequisites

- Synapse homeserver already deployed in the cluster
  (`kubernetes/base/apps/self-hosted/matrix/`). Reachable at
  `https://matrix.internal`.
- Your own Matrix account (`@nicolas:matrix.internal`) — used as
  `MATRIX_ALLOWED_USERS` so only you can talk to the bot.
- `kubectl` context pointing at the home cluster.

## Procedure

### 1. Register the bot user on Synapse

Find the Synapse pod (the deployment pod, not the CNPG DB pods):

```bash
kubectl -n self-hosted get pods -l app.kubernetes.io/name=synapse
# or more broadly:
kubectl -n self-hosted get pods | grep '^synapse-[0-9a-f]' | grep -v db
```

Then run Synapse's built-in user-creation tool inside that pod. It reads
the registration shared secret from the homeserver config:

```bash
kubectl -n self-hosted exec -it <synapse-pod> -- \
  register_new_matrix_user \
  -u hermes-bot \
  -p 'CHOOSE-A-STRONG-PASSWORD' \
  --no-admin \
  -c /data/homeserver.yaml \
  http://localhost:8008
```

`--no-admin` is intentional — the bot should not have server-admin rights.

### 2. Get an access token

Log in once as the new bot to get a long-lived access token. This goes
through the cluster ingress (`matrix.internal`), exactly like Element
would:

```bash
curl -sS -X POST "https://matrix.internal/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": "hermes-bot"},
    "password": "SAME-PASSWORD-AS-STEP-1",
    "initial_device_display_name": "hermes-muninn"
  }' | jq -r .access_token
```

Copy the token that comes out. You can throw the password away after
this — the token is what Hermes uses from here on.

### 3. Wire the credentials into the sops secret

Edit `secrets/muninn/secrets.sops.yaml` with sops:

```bash
sops secrets/muninn/secrets.sops.yaml
```

Under the `hermes-env` block (which already contains `OPENROUTER_API_KEY`
and `ANTHROPIC_API_KEY`), append the Matrix environment variables:

```yaml
hermes-env: |
  OPENROUTER_API_KEY=sk-or-...
  ANTHROPIC_API_KEY=sk-ant-...
  MATRIX_HOMESERVER=https://matrix.internal
  MATRIX_USER_ID=@hermes-bot:matrix.internal
  MATRIX_ACCESS_TOKEN=<token from step 2>
  MATRIX_ALLOWED_USERS=@nicolas:matrix.internal
  MATRIX_ENCRYPTION=true
```

Optional extras Hermes supports (see the Matrix gateway docstring in
`gateway/platforms/matrix.py` of the hermes-agent source):

| Var | Purpose |
|---|---|
| `MATRIX_DEVICE_ID` | Stable device ID so E2EE keys persist across bot restarts without re-verification. Useful once the bot has been verified. |
| `MATRIX_HOME_ROOM` | Room ID Hermes uses for scheduled/cron notifications. |
| `MATRIX_REQUIRE_MENTION` | Default `true`; `@hermes-bot` must be mentioned in rooms. |
| `MATRIX_AUTO_THREAD` | Auto-create a thread per conversation in rooms. Default `true`. |
| `MATRIX_RECOVERY_KEY` | Cross-signing recovery key for key rotation scenarios. |

### 4. Deploy muninn

No Nix-side changes are needed — all Matrix config is read from
`$HERMES_HOME/.env` inside the container, which `sops-install-secrets`
populates from the secret file. The only thing the deploy does is
re-encrypt + re-render the env file and recreate the hermes-agent
container so it picks up the new env.

```bash
just nix deploy muninn
```

**Caveat**: as with any hermes-agent container recreation, the writable
layer resets. You'll need to reinstall `agent-browser` and Chrome for
browser tools — see the chipmunk/muninn migration notes. Model APIs
(OpenRouter / Anthropic) work fine without reinstall.

### 5. Verify

From Element (or any Matrix client) logged in as `@nicolas:matrix.internal`:

1. Start a direct chat with `@hermes-bot:matrix.internal`.
2. Send "hi" or similar. Hermes should respond after a few seconds.
3. If E2EE is enabled and Element shows unverified device warnings,
   verify the bot from Element's session-management UI, or add
   `MATRIX_DEVICE_ID` + `MATRIX_RECOVERY_KEY` to skip ongoing verification
   churn.

If the bot does not respond, check logs on muninn:

```bash
ssh muninn.internal 'sudo docker logs hermes-agent 2>&1 | grep -i matrix | tail -30'
```

Common issues:

- Wrong homeserver URL (https vs http, typo)
- Expired / regenerated access token — rerun step 2
- `MATRIX_ALLOWED_USERS` missing your user ID — bot silently ignores DMs
  from unauthorised accounts
- Missing Ptinem Root CA inside the container — the hermes-agent uv2nix
  environment uses its own certs; if Synapse presents a private-CA-signed
  cert and the bot can't validate it, you'll see TLS errors in the logs.
  Usually handled via the global CA bundle the container picks up, but
  worth checking if TLS is the symptom.

## Rotation / Re-provisioning

If the token is ever leaked or the bot needs a clean restart:

1. Optional: deactivate the old bot account (Synapse admin API) or just
   regenerate the token by logging in again with the password from step 1
   — this invalidates any previously-issued token under the same session.
2. Re-run step 2 to get a fresh token.
3. Update `MATRIX_ACCESS_TOKEN` in the sops secret (step 3).
4. Redeploy muninn (step 4).
