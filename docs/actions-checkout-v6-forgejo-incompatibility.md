# actions/checkout v6 Incompatibility with Forgejo

## Problem Summary

`actions/checkout@v6` is incompatible with Forgejo runners and causes git authentication to fail. The workflow hangs indefinitely when attempting to push commits because git cannot authenticate with the remote repository.

## Root Cause

### v4/v5 Authentication (Working)

Both `actions/checkout@v4` and `v5` use a simple HTTP Authorization header approach:

```
http.https://forge.internal/.extraheader=AUTHORIZATION: basic <base64-encoded-token>
```

This sets a global git configuration that applies to all HTTPS operations for the host.

### v6 Authentication (Broken)

`actions/checkout@v6` uses conditional git config includes with hardcoded GitHub Actions runner paths:

```
includeif.gitdir:/github/workspace/.git.path=/github/runner_temp/git-credentials-<uuid>.config
includeif.gitdir:/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/hostexecutor/.git.path=/var/lib/gitea-runner/first/action-cache-dir/8df5c487204a1393/tmp/git-credentials-<uuid>.config
```

**The Problem:**
1. v6 creates conditional includes that point to GitHub Actions' standard paths (`/github/workspace/`, `/github/runner_temp/`)
2. Forgejo runners use completely different paths (`/var/lib/gitea-runner/*/action-cache-dir/*/`)
3. The conditional include for `/github/workspace/.git` never matches because the checkout happens in a Forgejo-specific path
4. Git cannot find the credentials, prompts for username/password, and times out waiting for input

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

## References

- **Commit History**: Git push dry-run test shows "Username for 'https://forge.internal': [TIMEOUT]" in v6 runs
- **GitHub Issue**: Consider opening an issue with `actions/checkout` about Forgejo compatibility if one doesn't exist
