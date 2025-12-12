# Forgejo Runner Upgrade Plan: v11.3.1 → v12.1.2

**Date:** 2025-12-12
**Host:** eagle.internal
**Status:** ⚠️ **DEPLOYED - ISSUES PERSIST**
**Updated:** 2025-12-12 (Post-deployment analysis)

## Executive Summary

⚠️ **CRITICAL UPDATE:** The upgrade to v12.1.2 was successfully deployed, but **DID NOT fix the job finalization and CPU spinning issues**. Extensive testing reveals the problems are **specific to workflows using `docker/setup-qemu-action@v3` and `docker/setup-buildx-action@v3`**.

**Key Findings:**
- ✅ Upgrade completed successfully (both runners running v12.1.2)
- ❌ Job finalization bug still occurs with Docker setup actions
- ✅ Simple workflows (checkout, git operations) work perfectly
- ❌ Workflows with Docker build actions fail despite all steps succeeding
- **Root cause identified:** Specific to docker/setup-qemu-action and docker/setup-buildx-action

## Deployment Results

### Test Workflow Results

Comprehensive testing with multiple workflows revealed the exact failure pattern:

| Workflow | Runner Label | Actions Used | Setup Time | Steps Result | Job Result | Notes |
|----------|--------------|--------------|------------|--------------|------------|-------|
| bump-flake | native | checkout, git-auto-commit | <5s | ✅ All passed | ✅ Success | Works perfectly |
| test-native | native | checkout only | <5s | ✅ All passed | ✅ Success | Baseline test |
| test-docker-simple | docker | checkout only | <10s | ✅ All passed | ✅ Success | Docker container works |
| **test-docker-actions-native** | **native** | **checkout + docker/setup-qemu@v3 + docker/setup-buildx@v3** | **1m43s** | **✅ All passed** | **❌ FAILED** | **Bug reproduced** |
| bitwarden-cli | native | checkout + docker/setup-qemu@v3 + docker/setup-buildx@v3 + build-push@v5 | 8m+ | ✅ All passed | ❌ FAILED | Original issue |

**Pattern Identified:** Jobs using **docker/setup-qemu-action@v3** and **docker/setup-buildx-action@v3** fail at job finalization stage despite all workflow steps (including post-cleanup) completing successfully.

### Symptoms Observed Post-Deployment

1. **Job Finalization Failure:**
   - All workflow steps execute successfully (✅)
   - All post-cleanup steps execute successfully (✅)
   - Runner **never logs "Cleaning up network for job"** message
   - Job status incorrectly reported as "failed" (❌)
   - Runner logs show task start but no completion entry

2. **Silent Runner Failure:**
   ```
   Dec 12 09:16:50 eagle act_runner[102844]: time="2025-12-12T09:16:50-05:00" level=info msg="task 6771 repo is nemo/avalanche"
   [NO FURTHER LOGS - RUNNER SILENTLY FAILED TO FINALIZE JOB]
   ```

3. **Cache Growth:**
   - First runner: 25K (healthy)
   - Second runner: 559MB (bloated during Docker action testing)

## Issues v12.1.2 Was Expected to Fix (BUT DIDN'T)

### 1. Job Finalization Hanging
- **Symptom:** Jobs complete successfully but are marked as failed
- **Root cause:** Runner never logs "Cleaning up network for job" message
- **Impact:** All workflow runs using Docker setup actions fail despite successful execution
- **Expected Fix:** v12.1.2 was assumed to resolve job cleanup logic
- **Actual Result:** ❌ **ISSUE PERSISTS** - Runner still fails to finalize jobs with docker/setup-qemu and docker/setup-buildx actions

### 2. CPU Spinning During Action Preparation
- **Symptom:** Multiple runner threads consuming 50-60% CPU during setup phase
- **Impact:** Jobs stuck after downloading actions, setup taking excessive time
- **Expected Fix:** v12.1.2 was assumed to include performance improvements
- **Actual Result:** ❌ **ISSUE PERSISTS** - CPU spinning still observed during Docker action preparation

### 3. Docker >28.1 Compatibility (ACTUALLY FIXED)
- **Issue:** "incorrect container platform option 'any'" error with modern Docker
- **Actual Result:** ✅ **FIXED** - This is the only issue v12.1.2 release notes mention fixing
- **Note:** This was the ONLY fix documented in v12.1.2 release notes; job finalization and CPU bugs were never mentioned

## Current Runner Configuration Analysis

### Cache System

**Configuration:**
```nix
settings = {
  cache = {
    enabled = true;
  };
  host = {
    workdir_parent = "${gitea-runner-directory}/action-cache-dir";
  };
};
```

**Locations:**
- First runner: `/var/lib/gitea-runner/first/action-cache-dir/`
- Second runner: `/var/lib/gitea-runner/second/action-cache-dir/`

**Issues Identified:**
1. **No cache size limits** - Can grow unbounded (reached 1.5GB before manual cleanup)
2. **No TTL configured** - Old/corrupted actions persist indefinitely
3. **Git version sensitivity** - NixOS 25.11 upgrade (git 2.47→2.51) caused cache corruption
   - Symptom: "Non-terminating error while running 'git clone': some refs were not updated"
   - Fix applied: Manual cache clear reduced from 1.3-1.5GB to 25K

**Recommendations:**
- Consider adding cache cleanup automation (systemd timer to clear caches older than 7 days)
- Monitor cache directory sizes (`du -sh /var/lib/gitea-runner/*/action-cache-dir/`)
- Document cache clear procedure for future git upgrades

### Storage Directories

**Workspace Structure:**
```
/var/lib/gitea-runner/
├── first/
│   ├── workspace/           # Job execution directory (container.workdir_parent)
│   ├── action-cache-dir/    # Downloaded GitHub Actions (host.workdir_parent)
│   └── home/                # Docker config, auth tokens (runner.envs.HOME)
└── second/
    ├── workspace/
    ├── action-cache-dir/
    └── home/
```

**Security Configuration:**
```nix
valid_volumes = [
  "/etc/ssl/certs/*"                        # Allow SSL cert mounts
  "/var/lib/gitea-runner/first/home"        # Allow home dir mounts
];

options = "--volume /etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro --volume /var/lib/gitea-runner/first/home:/var/lib/gitea-runner/first/home";
```

**Notes:**
- `valid_volumes` restricts what paths can be mounted (security feature)
- SSL certs mounted read-only for private CA support (step-ca)
- Home directory persistent for Docker config/credentials

### Docker Integration

**BuildKit Configuration:** `/etc/buildkit/buildkitd.toml`
```toml
[registry."forge.internal"]
  http = true
  insecure = true
  ca=["/etc/ssl/certs/ca-certificates.crt"]
```

**Docker Settings:**
- `autoPrune.enable = true` - Cleans up dangling images/containers
- Runners use both `native:host` and `docker:docker://node:24-bookworm` labels

### Environment Variables

```nix
runner = {
  envs = {
    HOME = "${gitea-runner-directory}/home";  # Required for dynamic user
    TZ = "America/New_York";                  # Timezone consistency
  };
};
```

**Why HOME is needed:** The `gitea-runner` user is dynamic (no home directory), so Docker would try creating `/.docker` without this.

## Implementation Approach

### Custom Package Strategy

Since nixpkgs (both stable and unstable) only have v11.3.1, we created a custom package:

**Location:** `nixos/pkgs/forgejo-runner-12/default.nix`

**Approach:**
1. Download official binary from Forgejo releases: `forgejo-runner-12.1.2-linux-arm64`
2. Use `fetchurl` with SHA256 hash: `4295b9bc62ba12ae5fc94f1f58c78266628def57bdfdfef89e662cdcb2cf2211`
3. Use `autoPatchelfHook` to fix dynamic library paths
4. Create `act_runner` symlink for backward compatibility with NixOS module
5. Add version check in `installCheckPhase`

**Why not build from source:**
- Faster deployment (no Go compilation)
- Official binary already tested by Forgejo team
- Easier to update (just change URL and hash)
- ARM64 cross-compilation on x86 workstations is slow

### Overlay Integration

**Added to:** `nixos/overlays/default.nix`
```nix
forgejo-runner-12 = final: prev: {
  forgejo-runner-12 = final.callPackage ../pkgs/forgejo-runner-12 { };
};
```

**Usage in eagle config:** `nixos/hosts/eagle/forgejo/forgejo-runner.nix`
```nix
services.gitea-actions-runner = {
  package = pkgs.forgejo-runner-12;  # Changed from: pkgs.unstable.forgejo-runner
  # ... rest of config unchanged
};
```

## Deployment Plan

### Pre-Deployment Checklist

- [x] Build validation: Tested on eagle.internal - **SUCCESS**
- [ ] Stop current runners: `sudo systemctl stop gitea-runner-first.service gitea-runner-second.service`
- [ ] Backup current cache state: `du -sh /var/lib/gitea-runner/*/action-cache-dir/` (for comparison)
- [ ] Note current runner PIDs/version: `ps aux | grep act_runner`

### Deployment Steps

1. **Commit changes to git:**
   ```bash
   git add nixos/pkgs/forgejo-runner-12/default.nix \
           nixos/overlays/default.nix \
           nixos/hosts/eagle/forgejo/forgejo-runner.nix
   git commit -m "feat(eagle): upgrade forgejo-runner to v12.1.2

   Fixes critical bugs:
   - Job finalization hanging (context canceled errors)
   - CPU spinning during action preparation
   - Docker >28.1 compatibility

   Uses custom package built from official Forgejo release binary
   until nixpkgs updates to v12.x.

   Ref: /home/ndufour/Documents/code/projects/bitwarden-cli/RUNNER_INVESTIGATION.md"
   git push
   ```

2. **Deploy to eagle:**
   ```bash
   just nix-deploy eagle
   # OR manually:
   # nixos-rebuild switch --flake .#eagle --target-host eagle.internal --use-remote-sudo
   ```

3. **Verify deployment:**
   ```bash
   ssh eagle.internal "
     # Check service status
     systemctl status gitea-runner-first.service gitea-runner-second.service

     # Verify version
     /nix/store/*/bin/act_runner --version | grep 12.1.2

     # Check runner logs
     journalctl -u gitea-runner-first.service -n 50
     journalctl -u gitea-runner-second.service -n 50
   "
   ```

4. **Test workflow run:**
   - Trigger a workflow in `nemo/bitwarden-cli` repository
   - Monitor logs: `ssh eagle.internal "journalctl -u gitea-runner-first.service -f"`
   - Verify:
     - ✅ Setup phase completes in <30s (with warm cache)
     - ✅ No CPU spinning (check `top` during setup)
     - ✅ Job completes with "Cleaning up network for job" message
     - ✅ Job status shows as succeeded (not "context canceled")

### Rollback Plan

If v12.1.2 causes issues:

1. **Revert git commit:**
   ```bash
   git revert HEAD
   git push
   ```

2. **Redeploy:**
   ```bash
   just nix-deploy eagle
   ```

3. **Or manual emergency rollback:**
   ```bash
   ssh eagle.internal "
     sudo systemctl stop gitea-runner-first.service gitea-runner-second.service
     # Note: NixOS will still have v11.3.1 in /nix/store from previous generation
     sudo nixos-rebuild switch --rollback
     sudo systemctl start gitea-runner-first.service gitea-runner-second.service
   "
   ```

## Post-Deployment Monitoring

### Metrics to Track

1. **Job success rate:** Should return to 100% (from current ~0% due to "context canceled")
2. **Setup phase duration:** Should be <30s with warm cache, ~4m for fresh cache
3. **CPU usage during setup:** Should be <20% (was 50-60% with v11.3.1)
4. **Cache growth:** Monitor `/var/lib/gitea-runner/*/action-cache-dir/` sizes

### Logs to Monitor

```bash
# Real-time monitoring
ssh eagle.internal "journalctl -u gitea-runner-first.service -f"

# Look for success indicators
ssh eagle.internal "journalctl -u gitea-runner-first.service --since '10 minutes ago' | grep -E '(Cleaning up network|Job succeeded|context canceled)'"
```

### Expected Log Patterns (v12.1.2)

**Success pattern:**
```
[timestamp] task 6XXX repo is nemo/bitwarden-cli
[timestamp] [actions/checkout@v6] Downloading action from cache
[timestamp] [docker/setup-buildx-action@v3] Downloading action from cache
... (setup completes quickly)
[timestamp] Build and push completed successfully
[timestamp] Cleaning up network for job docker  ← KEY SUCCESS INDICATOR
```

**Failure pattern to avoid (v11.3.1 bug):**
```
[timestamp] task 6XXX repo is nemo/bitwarden-cli
... (setup takes 3m48s+, CPU spinning)
[NO CLEANUP MESSAGE - JOB NEVER COMPLETES]
[timestamp] context canceled  ← BUG WE'RE FIXING
```

## Cache Management Recommendations

### Immediate Actions

None required - caches were cleared during investigation and are currently healthy (25K each).

### Future Automation

Consider adding a systemd timer for cache maintenance:

**File:** `nixos/hosts/eagle/forgejo/forgejo-runner-cache-cleanup.nix`
```nix
{ config, ... }:
{
  systemd.timers.forgejo-runner-cache-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  systemd.services.forgejo-runner-cache-cleanup = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.bash}/bin/bash -c '
          # Only clear if cache is larger than 500MB
          for runner in first second; do
            cache_dir="/var/lib/gitea-runner/$runner/action-cache-dir"
            size=$(du -sm "$cache_dir" | cut -f1)
            if [ "$size" -gt 500 ]; then
              echo "Clearing $runner cache (${size}MB > 500MB threshold)"
              rm -rf "$cache_dir"/*
            fi
          done
        '
      '';
    };
  };
}
```

**Rationale:**
- Prevents cache corruption from accumulating
- Limits disk usage growth
- Weekly cleanup is sufficient for runner workloads
- 500MB threshold allows cache to be useful while preventing unbounded growth

### Manual Cache Operations

**Check cache sizes:**
```bash
ssh eagle.internal "du -sh /var/lib/gitea-runner/*/action-cache-dir/"
```

**Clear specific runner cache:**
```bash
ssh eagle.internal "
  sudo systemctl stop gitea-runner-first.service
  sudo rm -rf /var/lib/gitea-runner/first/action-cache-dir/*
  sudo systemctl start gitea-runner-first.service
"
```

**Clear all runner caches:**
```bash
ssh eagle.internal "
  sudo systemctl stop gitea-runner-first.service gitea-runner-second.service
  sudo rm -rf /var/lib/gitea-runner/*/action-cache-dir/*
  sudo systemctl start gitea-runner-first.service gitea-runner-second.service
"
```

## Migration Path to Upstream Package

When nixpkgs eventually updates to v12.x:

1. **Check for updates:**
   ```bash
   nix eval nixpkgs#forgejo-runner.version
   nix eval nixpkgs-unstable#forgejo-runner.version
   ```

2. **Switch back to upstream:**
   ```nix
   # In nixos/hosts/eagle/forgejo/forgejo-runner.nix
   services.gitea-actions-runner = {
     package = pkgs.unstable.forgejo-runner;  # or pkgs.forgejo-runner if in stable
   };
   ```

3. **Remove custom package:**
   ```bash
   rm -rf nixos/pkgs/forgejo-runner-12/
   # Remove overlay from nixos/overlays/default.nix
   ```

4. **Update documentation** to reflect using upstream package

## Known Limitations

1. **ARM64 only:** Current package only supports `aarch64-linux` (eagle's architecture)
   - If runners move to x86_64, update package to use `forgejo-runner-12.1.2-linux-amd64`

2. **Binary-only package:** Not building from source
   - Pro: Faster deployment, official tested binary
   - Con: Less transparency than source build, requires trusting Forgejo binaries

3. **autoPatchelfHook dependency:** Binary requires patching for NixOS
   - Should work automatically, but if runner fails to start, check: `ldd /nix/store/*/bin/forgejo-runner`

## References

- **Investigation document:** `/home/ndufour/Documents/code/projects/bitwarden-cli/RUNNER_INVESTIGATION.md`
- **Forgejo runner releases:** https://code.forgejo.org/forgejo/runner/releases
- **v12.1.2 release notes:** https://code.forgejo.org/forgejo/runner/releases/tag/v12.1.2
- **NixOS gitea-actions-runner module:** https://search.nixos.org/options?query=services.gitea-actions-runner
- **Current nixpkgs package:** https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/fo/forgejo-runner/package.nix

## Success Criteria (Post-Deployment Assessment)

### Deployment Success
- [x] Package builds successfully on eagle (VERIFIED)
- [x] Both runner services start without errors (VERIFIED - both running v12.1.2)
- [x] Version shows as v12.1.2 (VERIFIED via `forgejo-runner --version`)

### Functional Success (❌ FAILED)
- [x] Simple workflows complete successfully (bump-flake, test-native, test-docker-simple)
- [❌] **FAILED:** Docker setup action workflows complete with "succeeded" status
  - **Result:** Jobs using docker/setup-qemu-action@v3 and docker/setup-buildx-action@v3 marked as failed
- [❌] **FAILED:** Setup phase completes in <30s with warm cache
  - **Result:** test-docker-actions-native took 1m43s, bitwarden-cli took 8m+
- [❌] **FAILED:** CPU usage during setup is <20%
  - **Result:** CPU spinning still observed during action preparation
- [❌] **FAILED:** Logs show "Cleaning up network for job" message
  - **Result:** Runner silently fails to log job completion
- [~] **PARTIAL:** Cache stability - First runner 25K (good), Second runner 559MB (bloated)

**Overall Upgrade Assessment:** ⚠️ **DEPLOYMENT SUCCESSFUL, BUT CORE ISSUES PERSIST**

## Updated Recommendations (Post-Testing)

### Immediate Actions

1. **Clear Second Runner Cache:**
   ```bash
   ssh eagle.internal "
     sudo systemctl stop gitea-runner-second.service
     sudo rm -rf /var/lib/gitea-runner/second/action-cache-dir/*
     sudo systemctl start gitea-runner-second.service
   "
   ```

2. **Monitor Cache Growth:**
   ```bash
   watch -n 60 'ssh eagle.internal "sudo du -sh /var/lib/gitea-runner/*/action-cache-dir/"'
   ```

### Short-term Options

**Option A: Keep v12.1.2, Workaround Docker Actions Issue**
- Pros: Already deployed, simple workflows work fine
- Cons: Bitwarden-cli builds still fail
- Actions:
  1. Try disabling cache to see if it helps
  2. Test alternative Docker build approaches (docker buildx directly without setup actions)
  3. Report bug to Forgejo with test case

**Option B: Rollback to v11.3.1**
- Pros: Known behavior, no worse than before
- Cons: Same issues exist in v11.3.1, wasted upgrade effort
- Actions:
  ```bash
  # Revert commits
  git revert HEAD~3..HEAD  # Revert test workflows and upgrade
  git push
  just nix-deploy eagle
  ```

**Option C: Try Configuration Workarounds**
- Pros: May fix issues without changing versions
- Cons: Unknown if effective, requires testing
- Actions to test:
  1. Disable cache (`cache.enabled = false`)
  2. Add task finalization retry config (v12.0.0 feature)
  3. Increase timeouts for action fetching

### Long-term Solutions

1. **Report Bug to Forgejo:**
   - File issue at https://code.forgejo.org/forgejo/runner/issues
   - Provide minimal reproduction case (test-docker-actions-native workflow)
   - Include evidence: all steps succeed, runner never logs completion
   - Reference similar issues found in testing

2. **Alternative Build Approach for bitwarden-cli:**
   - **Option 1:** Use `docker buildx` directly without setup-qemu/setup-buildx actions
   - **Option 2:** Build locally and push image separately
   - **Option 3:** Use different CI/CD platform for Docker builds (Drone, GitLab CI)

3. **Monitor Forgejo Updates:**
   - Watch for v12.2.x or v13.x releases mentioning job finalization fixes
   - When nixpkgs updates to v12.x, migrate from custom package to upstream

### Testing Framework Established

The test workflows created provide a reproducible test suite:

- `.forgejo/workflows/test-docker.yaml` - Tests native vs docker runner labels
- `.forgejo/workflows/test-docker-native.yaml` - Reproduces Docker setup action bug

These can be used to:
- Verify future runner version upgrades
- Test configuration changes
- Provide bug reports to Forgejo maintainers

## Known Issues and Limitations (Updated)

### Critical Issues

1. **Docker Setup Actions Cause Job Finalization Failure (v12.1.2):**
   - Affects: Workflows using docker/setup-qemu-action@v3 and docker/setup-buildx-action@v3
   - Symptom: All steps succeed, job marked as failed
   - Root cause: Runner fails to finalize job, never logs completion
   - Workaround: None identified yet
   - Status: ❌ **BLOCKING bitwarden-cli builds**

2. **Cache Unbounded Growth:**
   - Second runner cache grew to 559MB during Docker action testing
   - No automatic cleanup mechanism
   - Manual intervention required
   - Workaround: Periodic manual cache clearing

### Package Limitations

1. **ARM64 only:** Current package only supports `aarch64-linux` (eagle's architecture)
   - If runners move to x86_64, update package to use `forgejo-runner-12.1.2-linux-amd64`

2. **Binary-only package:** Not building from source
   - Pro: Faster deployment, official tested binary
   - Con: Less transparency than source build, requires trusting Forgejo binaries

3. **autoPatchelfHook dependency:** Binary requires patching for NixOS
   - Should work automatically, but if runner fails to start, check: `ldd /nix/store/*/bin/forgejo-runner`

## References (Updated)

### Investigation & Testing
- **Original investigation:** `/home/ndufour/Documents/code/projects/bitwarden-cli/RUNNER_INVESTIGATION.md`
- **Test workflows:** `.forgejo/workflows/test-docker*.yaml` in avalanche repo

### Forgejo Resources
- **Runner releases:** https://code.forgejo.org/forgejo/runner/releases
- **v12.1.2 release notes:** https://code.forgejo.org/forgejo/runner/releases/tag/v12.1.2 (only mentions Docker >28.1 fix)
- **Runner issues:** https://code.forgejo.org/forgejo/runner/issues
- **Configuration example:** https://code.forgejo.org/forgejo/runner/src/branch/main/internal/pkg/config/config.example.yaml

### Related Issues Found
- **Runner stuck in Set up job:** https://www.synoforum.com/threads/forgejo-runner-stuck-in-set-up-job.14950/
- **Docker setup-buildx issues:** https://github.com/docker/setup-buildx-action/discussions/343
- **Forgejo runner Docker connectivity:** https://code.forgejo.org/forgejo/runner/issues/153

### NixOS Resources
- **NixOS gitea-actions-runner module:** https://search.nixos.org/options?query=services.gitea-actions-runner
- **Current nixpkgs package:** https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/fo/forgejo-runner/package.nix

## Approval & Sign-off

**Prepared by:** Claude Code
**Deployment Date:** 2025-12-12
**Deployed by:** User
**Status:** ✅ Deployed, ⚠️ Core issues persist

**Post-Deployment Notes:**
- Upgrade to v12.1.2 completed successfully
- Runners operational but job finalization bug remains
- Specific to docker/setup-qemu-action and docker/setup-buildx-action
- Simple workflows work perfectly
- Further investigation or alternative approaches needed for Docker builds
