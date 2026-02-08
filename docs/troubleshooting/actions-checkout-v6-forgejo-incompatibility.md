# actions/checkout v6 Incompatibility with Forgejo

## Problem Summary

`actions/checkout@v6` is incompatible with Forgejo runners and causes git authentication to fail. The workflow hangs indefinitely when attempting to push commits because git cannot authenticate with the remote repository.

## Root Cause

### v4/v5 Authentication (Working)

Both `actions/checkout@v4` and `v5` use a simple HTTP Authorization header approach:

```
http.https://forge.internal/.extraheader=AUTHORIZATION: basic <base64-encoded-token>
```

This sets a global git configuration that applies to all HTTPS operations for the host. The credentials are stored directly in git config and are immediately available.

### v6 Authentication (Broken)

Starting with v6, `actions/checkout` moved away from storing credentials in git config. According to the v6 changelog:

> Updated `persist-credentials` to store the credentials under `$RUNNER_TEMP` instead of directly in the local git config.
> This requires a minimum Actions Runner version of [v2.329.0](https://github.com/actions/runner/releases/tag/v2.329.0)

Instead of using HTTP Authorization headers, v6 now uses conditional git config includes that load credentials from temporary files:

```
includeif.gitdir:/github/workspace/.git.path=/github/runner_temp/git-credentials-<uuid>.config
includeif.gitdir:/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/hostexecutor/.git.path=/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/tmp/git-credentials-<uuid>.config
```

**The Problem:**

1. v6 assumes the runner will provide `$RUNNER_TEMP` and set up credential files at known paths
2. Forgejo runners use different directory structures (`/var/lib/gitea-runner/*/action-cache-dir/*/tmp/`) compared to GitHub Actions (`/github/runner_temp/`, `/github/workspace/`)
3. v6 hardcodes GitHub Actions paths in the conditional includes, creating entries for `/github/workspace/` and `/github/runner_temp/` that don't exist on Forgejo
4. The Forgejo-specific path is also included, but the credentials may not be properly persisted or accessible in the format v6 expects
5. When git tries to authenticate, it cannot find valid credentials in any of the configured paths
6. Git falls back to prompting for username/password interactively, which times out waiting for input in a CI environment

## Evidence

### Git Config Comparison

**After `actions/checkout@v4`:**
```
remote.origin.url=https://forge.internal/***/avalanche
http.https://forge.internal/.extraheader=AUTHORIZATION: basic ***
```

**After `actions/checkout@v5`:**
```
remote.origin.url=https://forge.internal/***/avalanche
http.https://forge.internal/.extraheader=AUTHORIZATION: basic ***
```

**After `actions/checkout@v6`:**
```
remote.origin.url=https://forge.internal/***/avalanche
includeif.gitdir:/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/hostexecutor/.git.path=/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/tmp/git-credentials-<uuid>.config
includeif.gitdir:/github/workspace/.git.path=/github/runner_temp/git-credentials-<uuid>.config
```

### Behavioral Impact

When `nix flake update` creates changes and the workflow attempts to push:

- **v4/v5**: Push succeeds within seconds using the HTTP Authorization header
- **v6**: Git prompts for username, times out after 60 seconds, workflow fails with context deadline exceeded after ~26+ minutes

## Solution

**Use `actions/checkout@v5`** instead of v6:
- Fully compatible with Forgejo runners
- Uses the reliable HTTP Authorization header approach
- No breaking changes compared to v4

## Pinning Configuration

To prevent accidental upgrades to v6, the renovate configuration pins `actions/checkout` to `v5.x` with no major version upgrades.

## Technical Details - Source Code Analysis

The hardcoded paths are located in `src/git-auth-helper.ts`:

**Lines 166-169** (submodule credentials):
```typescript
const containerCredentialsPath = path.posix.join(
  '/github/runner_temp',  // ❌ Hardcoded GitHub path
  path.basename(credentialsConfigPath)
)
```

**Lines 383-397** (main repository credentials):
```typescript
const containerGitDir = path.posix.join(
  '/github/workspace',    // ❌ Hardcoded GitHub path
  relativePath,
  '.git'
)

const containerCredentialsPath = path.posix.join(
  '/github/runner_temp',  // ❌ Hardcoded GitHub path
  path.basename(credentialsConfigPath)
)
```

**The irony:** The code already has access to the correct environment variables:
- Line 91 & 256: `const runnerTemp = process.env['RUNNER_TEMP']` ✅
- Line 379: `const githubWorkspace = process.env['GITHUB_WORKSPACE']` ✅

The fix is trivial - use these variables instead of hardcoding paths. This would make v6 work universally on GitHub Actions, Forgejo, Gitea, and any other CI system that sets these standard environment variables.

## See Also

- [Plan to replace actions/checkout with raw git commands](../plans/replace-actions-checkout.md) — migration plan to drop the dependency entirely

## References

- **GitHub Issue**: [#2321 - actions/checkout@v6 broken on non-GitHub runners (Forgejo, Gitea, etc.)](https://github.com/actions/checkout/issues/2321)
- **Related Issue**: [#2318 - Same root cause affects Git worktrees](https://github.com/actions/checkout/issues/2318)
- **Source PR**: [#2286 - Persist creds to a separate file](https://github.com/actions/checkout/pull/2286)
