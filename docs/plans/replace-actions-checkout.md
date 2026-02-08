# Replace actions/checkout with Raw Git Commands

## Background

`actions/checkout@v6` broke compatibility with non-GitHub runners (Forgejo, Gitea,
custom Docker setups) by replacing the universal HTTP auth header approach (v4/v5)
with path-dependent `includeIf.gitdir` directives hardcoded to GitHub's filesystem
layout (`/github/workspace/`, `/github/runner_temp/`).

Multiple users reported this independently:

- **[#2321](https://github.com/actions/checkout/issues/2321)** (us) — Forgejo runners
  fail because the `includeIf` paths don't match the actual workspace. Closed by the
  maintainer as "runner misconfiguration" with the suggestion that the action dynamically
  detects the workspace path — ignoring that the path detection relies on GitHub-specific
  environment variable assumptions.

- **[#2359](https://github.com/actions/checkout/issues/2359)** — Docker container actions
  break because credential files at host paths aren't accessible inside containers. A
  commenter from Materialize nailed it: *"this change requires the git repository and
  temporary path containing the credentials to live at specific paths within the docker
  image, which was not the case before."* Maintainer tried to reproduce, said it worked
  for him.

- **[#2322](https://github.com/actions/checkout/issues/2322)** — User spent 30+ minutes
  trying to understand what v6 even changed because the changelog was vague. This one
  actually got a docs update, so at least something came out of it.

The pattern is clear: GitHub doesn't care about non-GitHub runners. The v4/v5 approach
was universally compatible by design. v6 traded that for a marginal security improvement
(credentials in a separate file instead of `.git/config`) that only benefits GitHub's
own infrastructure. Every report from non-GitHub users was either dismissed or met with
"works on my machine."

We're currently pinned to v5, which works. But v5 will eventually stop receiving updates,
and there's no reason to depend on 1,500 lines of TypeScript for what amounts to a
`git clone`.

## What actions/checkout Actually Does

For our workflows, the only relevant operations are:

1. `git clone --depth 1` the repository
2. Authenticate using the runner token
3. Optionally configure user name/email for push workflows

Everything else it does (LFS, sparse checkout, submodules, safe directory hacks, GC
tuning, credential cleanup) is unused.

## Replacement

### Native runner (`runs-on: native`)

```yaml
steps:
  - run: |
      git clone --depth 1 --branch ${GITHUB_REF_NAME} \
        https://token:${GITHUB_TOKEN}@forge.internal/${GITHUB_REPOSITORY}.git .
```

For workflows that push back (e.g., `bump-flake.yaml`):

```yaml
steps:
  - run: |
      git clone --depth 1 --branch ${GITHUB_REF_NAME} \
        https://token:${GITHUB_TOKEN}@forge.internal/${GITHUB_REPOSITORY}.git .
      git config user.name "forgejo-actions"
      git config user.email "actions@forge.internal"
```

### Docker runner (`runs-on: docker`)

Same commands — `node:24-bookworm` already includes git. The runner injects
`GITHUB_TOKEN` and other environment variables into the container automatically.

Only potential issue: DNS resolution of `forge.internal` inside the container.
Docker uses host DNS by default, so this should work since the host is on Tailscale.
If not, use the direct IP or add an extra host mapping.

## Workflows to Update

| Workflow | Runner | Pushes back? |
|----------|--------|-------------|
| `bump-flake.yaml` | native | Yes (auto-commit) |
| `build-npu-inference.yaml` | native | No |
| `build-argocd-cmp.yaml` | native | No |

## Migration Steps

1. Pick one workflow (e.g., `build-argocd-cmp.yaml` — no push, low risk)
2. Replace `uses: actions/checkout@v5` with the raw git clone
3. Verify it works
4. Roll out to remaining workflows
5. Remove any `actions/checkout` references from Forgejo's action cache
