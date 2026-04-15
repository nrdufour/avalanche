# chipmunk — Hermes Agent Migration Plan

Rename `lobster` → `chipmunk` and replace the `oh-my-opencode` / openclaw experiment with Hermes Agent (NousResearch) as an always-on task agent, while keeping `claude-code` on the same host for interactive coding work.

## Goals

- Rename the host to match the "animal of the garden" theme (`lobster` → `chipmunk`).
- Install Hermes Agent via its upstream NixOS module in **container mode**, so the agent can `apt`/`pip`/`npm install` freely without polluting the NixOS layer.
- Start in **CLI-only mode** (no gateway). SSH to chipmunk, run `hermes`. A messaging gateway can be added later as a separate commit.
- Use **Anthropic directly** as the model backend (user has a funded API account; Claude Code subscription cannot be reused for a different client).
- Keep `claude-code` available on the host via the existing `llm-agents` flake input.
- Persist Hermes state on the USB stick at `/srv` so the SD card does not take the agent's write load.

## Out of scope (explicitly, for later)

- Gateway setup (Signal / Email / Discord decision deferred). Matrix is **not** a supported Hermes gateway — confirmed from upstream README.
- Forgejo bot account + token + MCP wiring. Will be a follow-up commit.
- Local-model inference. Not running on chipmunk (Pi 4, no GPU). When we want it, it lives on a different host and Hermes points `base_url` at an OpenAI-compatible endpoint.
- Removing `oh-my-opencode` from `nixos/personalities/development/ai.nix:106` (other hosts still import it).

## Prerequisites

- Anthropic API key available (user confirmed).
- Access to the Pi 4 via Tailscale as `lobster.internal` for the initial deploy; DNS will flip to `chipmunk.internal` after the rename.
- `fj` / Forgejo access to push the rename branch.

## Rename surface (full inventory)

Every file that mentions `lobster` today:

| File | Line(s) | What it is |
|---|---|---|
| `flake.nix` | 132–142 | `nixosConfigurations.lobster` entry |
| `nixos/hosts/lobster/default.nix` | 23, 37, 46 | Host module: hostname, sops path, autoUpgrade comment |
| `nixos/hosts/lobster/tailscale.nix` | — | Tailscale config (path move only) |
| `.sops.yaml` | 5, 47, 52 | Age key anchor + creation rule |
| `secrets/lobster/secrets.sops.yaml` | — | Encrypted secrets (path move + re-encrypt) |
| `nixos/hosts/routy/knot/static-records.nix` | 43, 100 | Internal DNS A record + PTR |
| `nixos/hosts/routy/kea/dhcp.nix` | 232–234 | DHCP reservation (hostname field only — MAC + IP stay) |
| `kubernetes/base/infra/observability/kube-prometheus-stack/scrapeconfig.yaml` | 10 | Prometheus scrape target |
| `CLAUDE.md` | — | Two mentions under "NixOS Hosts" + "Key Technologies" |

## Stage 1 — Rename `lobster` → `chipmunk` (standalone commit)

Treat this as an isolated, revertible commit. No Hermes changes yet.

1. **Generate a new age key on the host** (ssh into `lobster.internal`):
   ```bash
   nix-shell -p age --run "age-keygen -o /tmp/chipmunk-age.txt"
   ```
   Copy the public key. Plan to install the private key at the same sops-nix path currently used for the lobster key once the rename deploys.

2. **Rewrite `.sops.yaml`**:
   - Add `&server-chipmunk <new-pubkey>` alongside (not replacing) `&server-lobster`.
   - Add a new `path_regex: secrets/chipmunk/[^/]+\.(yaml|json|env|ini)$` creation rule with `*server-chipmunk` and your admin key.
   - Keep the old `server-lobster` anchor + rule in place for one commit so re-encryption has both keys available. (Drop them at the end of this stage.)

3. **Move secrets**:
   ```bash
   git mv secrets/lobster secrets/chipmunk
   just sops update           # re-encrypts under new rules
   ```
   Verify admin can still decrypt: `sops -d secrets/chipmunk/secrets.sops.yaml`.

4. **Move the host module**:
   ```bash
   git mv nixos/hosts/lobster nixos/hosts/chipmunk
   ```
   Edit `nixos/hosts/chipmunk/default.nix`:
   - `networking.hostName = "chipmunk";`
   - `sops.defaultSopsFile = ../../../secrets/chipmunk/secrets.sops.yaml;`
   - Update the "lobster is a testing/agent-runner" comment.

5. **Edit `flake.nix:132-142`**: rename the attr key from `lobster` to `chipmunk`, `hostname = "chipmunk"`, update path in any `./nixos/hosts/…` reference.

6. **Edit DNS + DHCP on routy**:
   - `nixos/hosts/routy/knot/static-records.nix:43`, `:100` → `chipmunk`
   - `nixos/hosts/routy/kea/dhcp.nix:232` → `hostname = "chipmunk"` (IP `10.1.0.99` and MAC stay — it's the same NIC).

7. **Edit Prometheus scrape config**: `kubernetes/base/infra/observability/kube-prometheus-stack/scrapeconfig.yaml:10` → `chipmunk.internal:9002`.

8. **Edit `CLAUDE.md`**: replace the two `lobster` mentions with `chipmunk`.

9. **Drop the old lobster sops anchor + rule** from `.sops.yaml` (final sub-step — only after re-encryption succeeded with both keys present). Re-run `just sops update` to verify the file still decrypts with only the new key.

10. **Local build smoke test** before touching the host:
    ```bash
    nix flake check
    nix build .#nixosConfigurations.chipmunk.config.system.build.toplevel
    ```

11. **Deploy**:
    - First deploy still goes to `lobster.internal` (DNS not updated yet). After the new config applies, the host identifies as `chipmunk` but is reachable at the old hostname until routy is redeployed.
    - **Write the new private age key to the host** at its existing sops-nix path before rebooting, or the next boot cannot decrypt secrets. Double-check the path from `sops.age.keyFile` in the role profile.
    - Deploy routy (DNS + DHCP update).
    - Verify `chipmunk.internal` resolves, SSH works, `hostname` returns `chipmunk`, sops secrets decrypt (`systemctl status sops-nix` or check a service that depends on a secret).
    - Rename the host in the Tailscale admin console (manual, out-of-band).

12. **Commit**: single commit, message along the lines of `chore(hosts): rename lobster → chipmunk`.

**Rollback for Stage 1**: `git revert` the commit, redeploy routy (DNS back), redeploy the host (now reachable via old DNS name after Tailscale rename reverts).

## Stage 2 — Add Hermes Agent flake input

Separate commit from the rename so a bad Hermes build does not block the rename revert.

1. Add flake input in `flake.nix`:
   ```nix
   inputs.hermes-agent = {
     url = "github:NousResearch/hermes-agent";
     inputs.nixpkgs.follows = "nixpkgs";   # if upstream exposes it
   };
   ```
2. Pass `inputs` through to the chipmunk host module (it already receives `inputs`, per `nixos/hosts/chipmunk/default.nix:1`).
3. `nix flake lock --update-input hermes-agent`; commit `flake.lock`.
4. **Sanity-build on x86** before deploying: `nix build .#nixosConfigurations.chipmunk.config.system.build.toplevel`. If Hermes' uv2nix-built Python deps fail on aarch64 cross, we find out here, not on the Pi.

## Stage 3 — Enable Hermes on chipmunk (the actual payload)

1. Create `nixos/hosts/chipmunk/hermes.nix`:
   ```nix
   { config, inputs, ... }: {
     imports = [ inputs.hermes-agent.nixosModules.default ];

     services.hermes-agent = {
       enable = true;
       container.enable = true;           # Ubuntu writable layer for apt/pip/npm
       environmentFiles = [ config.sops.secrets."hermes-env".path ];
       settings.model = {
         # Anthropic direct — user has an API account, no OpenRouter.
         base_url = "https://api.anthropic.com";
         default  = "claude-sonnet-4-5";  # verify exact native ID before deploy
       };
     };
   }
   ```
   **Verify the exact Anthropic native model ID** against Hermes' config reference before committing — the docs page I read only gave OpenRouter-style IDs (`anthropic/claude-sonnet-4`). Direct-Anthropic IDs use the Anthropic API naming (`claude-sonnet-4-5`, `claude-opus-4-6`, etc.). This is a likely snag; budget 10 minutes to check upstream.

2. Import `./hermes.nix` from `nixos/hosts/chipmunk/default.nix`.

3. **Sops secret** — add to `secrets/chipmunk/secrets.sops.yaml`:
   ```yaml
   hermes-env: |
     ANTHROPIC_API_KEY=sk-ant-...
   ```
   Wire it in the chipmunk module:
   ```nix
   sops.secrets."hermes-env" = {
     sopsFile = ../../../secrets/chipmunk/secrets.sops.yaml;
     mode = "0400";
     # owner/group set to whatever UID the hermes-agent module uses; check upstream
   };
   ```
   **Open question**: confirm the systemd service's user so secret permissions line up. Check after first `nix build` by grepping the generated service file.

4. **Workspace on `/srv`** — Hermes default is `/var/lib/hermes`. Chipmunk already has the USB stick mounted at `/srv` (`default.nix:17-20`). Pick one of:
   - **Bind mount** (cleanest, NixOS-idiomatic):
     ```nix
     fileSystems."/var/lib/hermes" = {
       device = "/srv/hermes";
       options = [ "bind" ];
     };
     systemd.tmpfiles.rules = [ "d /srv/hermes 0750 root root -" ];
     ```
   - **Override HERMES_HOME** if the upstream module exposes a `stateDir` / `homeDir` option (check `services.hermes-agent.settings` or equivalent — I did not see one named in the Nix setup page, so a bind mount is the safer bet).

   Bind mount is my recommendation until we confirm an option exists.

5. **Remove `oh-my-opencode`** from `nixos/hosts/chipmunk/default.nix:42` — keep `claude-code` on line 41. Do **not** touch `nixos/personalities/development/ai.nix` (other hosts use it).

6. **Build + deploy**:
   ```bash
   nix build .#nixosConfigurations.chipmunk.config.system.build.toplevel
   just nix deploy chipmunk
   ```

7. **First-run verification** on the host:
   ```bash
   systemctl status hermes-agent
   journalctl -u hermes-agent --since "5 min ago"
   sudo ls -la /srv/hermes                  # state is on the USB stick
   sudo -u hermes hermes --version           # or whatever user the service runs as
   sudo -u hermes hermes chat                # smoke-test one prompt
   ```
   A successful Anthropic round-trip confirms the API key, model ID, and network egress (no VPN proxy needed — api.anthropic.com is public and not on the `10.1.0.1:1080` path).

8. **Commit**: `feat(chipmunk): install hermes-agent with anthropic backend`.

**Rollback for Stage 3**: revert the commit, redeploy. State under `/srv/hermes` is preserved across revert (we don't delete the dir), so a later re-enable picks up where it left off.

## Stage 4 — Verification checklist (before declaring done)

- [ ] `hostname` on the host returns `chipmunk`.
- [ ] `chipmunk.internal` resolves via Knot; `lobster.internal` no longer resolves.
- [ ] DHCP lease for MAC `d8:3a:dd:17:1e:1b` shows hostname `chipmunk` in kea logs.
- [ ] Tailscale admin console shows the device as `chipmunk`.
- [ ] `just nix deploy chipmunk` is a no-op (idempotent build).
- [ ] `sops -d secrets/chipmunk/secrets.sops.yaml` works from admin workstation.
- [ ] `systemctl status hermes-agent` is `active (running)`.
- [ ] `sudo -u hermes hermes chat` completes one round-trip against Anthropic.
- [ ] Prometheus node-exporter target `chipmunk.internal:9002` is `up` in Grafana.
- [ ] `claude-code` still launches and works for the user interactively.

## Known unknowns / questions surfaced by the plan

These are things I could not confirm from the Hermes Nix setup page and will need to verify before or during Stage 3:

1. **aarch64 build**. Upstream uses uv2nix for Python deps. Some Python wheels lack aarch64 variants. If `nix build` fails on the Pi, we may need to cross-build on calypso or wait for upstream fixes.
2. **Exact Anthropic native model ID string** accepted by Hermes when `base_url` is set directly.
3. **Service user UID/GID** for secret ownership (affects the `sops.secrets` block).
4. **Whether the module exposes a state-dir option** that would let us skip the bind mount.
5. **Container mode disk footprint** — not specified. The USB stick needs to have room for an Ubuntu rootfs + agent downloads. Worth `df -h /srv` before starting.

None of these are blockers; they're "read one more doc page or test build" items. I'll hit them in order once Stage 1 is merged.

## Future work (tracked here, not executed)

- **Gateway**: Signal vs Email vs Discord. Decision deferred until Hermes is running in CLI mode and the user has a feel for whether it's worth making always-on.
- **Forgejo bot**: dedicated account, token in sops, either a Forgejo MCP server (if one exists) or plain `git` over HTTPS with the token in the URL.
- **Local model backend**: deploy an OpenAI-compatible inference endpoint on a GPU-capable host, point `settings.model.base_url` at it. Chipmunk stays the agent runner; inference moves elsewhere.
- **SOUL.md / USER.md personalization**: seed the persistent personality/context files once the agent is running.
