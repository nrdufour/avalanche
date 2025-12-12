# Forgejo Runner Upgrade Plan: v11.3.1 → v12.1.2

**Date:** 2025-12-12
**Host:** eagle.internal
**Status:** Ready for deployment

## Executive Summary

Upgrading forgejo runners from v11.3.1 to v12.1.2 to fix critical bugs causing job failures. The upgrade uses a custom NixOS package built from official Forgejo binaries since nixpkgs doesn't yet have v12.x.

## Critical Issues Fixed by v12.1.2

### 1. Job Finalization Hanging
- **Symptom:** Jobs complete successfully but are marked as failed with "context canceled"
- **Root cause:** Runner never logs "Cleaning up network for job" message
- **Impact:** All workflow runs fail despite successful execution
- **Fix:** v12.1.2 resolves job cleanup logic

### 2. CPU Spinning During Action Preparation
- **Symptom:** Multiple runner threads consuming 50-60% CPU during setup phase
- **Evidence from investigation:**
  - Thread 95708: 19% CPU, 1:12 CPU time
  - Thread 95423: 13% CPU, 1:13 CPU time
  - Thread 95417: 10% CPU, 0:57 CPU time
- **Impact:** Jobs stuck after downloading ~2,834 files, setup taking 3m48s-4m20s
- **Fix:** v12.1.2 includes performance improvements during action preparation

### 3. Docker >28.1 Compatibility
- **Issue:** "incorrect container platform option 'any'" error with modern Docker
- **Fix:** v12.1.2 adds compatibility with Docker 28.1+

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

## Success Criteria

The upgrade is successful when:

- [x] Package builds successfully on eagle (VERIFIED)
- [ ] Both runner services start without errors
- [ ] Version shows as v12.1.2 (`forgejo-runner --version`)
- [ ] Test workflow completes with "succeeded" status (not "context canceled")
- [ ] Setup phase completes in <30s (with warm cache)
- [ ] CPU usage during setup is <20% (not 50-60%)
- [ ] Logs show "Cleaning up network for job" message
- [ ] Cache remains stable (<100MB) after 5+ workflow runs

## Approval & Sign-off

**Prepared by:** Claude Code
**Reviewed by:** _[User to approve]_
**Approved for deployment:** ☐ Yes ☐ No ☐ With modifications

**Notes:**
