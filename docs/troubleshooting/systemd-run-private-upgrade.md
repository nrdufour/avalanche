# systemd /run/private Permission Mismatch on Service Restart

## Incident: 2026-02-08

### Summary

At 03:00 EST, routy's scheduled autoupgrade pulled a NixOS configuration that
included a systemd update from 258.2 to 258.3. The build succeeded and
`switch-to-configuration switch` began activating the new system. During service
restart, all services using `DynamicUser=yes` (kea-dhcp4-server, kea-dhcp-ddns-server,
adguardhome) failed to start with:

```
Directory "/run/private" already exists, but has mode 0710 that is too permissive
(0700 was requested), refusing.
```

With DHCP and DNS down, the entire home network lost connectivity. Kea entered a
crash loop (restart counter reached 2316 over ~3.5 hours) until a manual reboot
resolved the issue at ~06:47 EST.

### Root Cause

systemd 258.3 has an internal inconsistency in how it handles `/run/private`:

1. **At boot**, systemd (PID 1) creates `/run/private` with mode **0710**
2. **Initial service start** (at boot) works fine — systemd uses a creation
   code path that doesn't validate the parent directory's existing permissions
3. **Any subsequent service restart** fails — systemd's `mkdirat_safe_internal()`
   (in `src/basic/mkdir.c`) validates the existing `/run/private` against mode
   0700 and rejects 0710:

```c
if ((st.st_mode & ~mode & 0777) != 0)
    // "Directory already exists, but has mode %04o that is too permissive
    //  (%04o was requested), refusing."
```

The group-execute bit (010) is present in the existing directory (0710) but not
in the requested mode (0700), so the check fails.

Key observations:
- systemd itself creates `/run/private` as 0710 at boot
- systemd's `mkdir_safe` rejects 0710 as "too permissive" when 0700 is requested
- The **first** start at boot always works (different code path)
- **Any restart** after boot fails (validation path)
- `chmod 0700 /run/private` fixes it and the mode stays 0700 for the session
- This is **not** specific to upgrades — a simple `systemctl restart` triggers it

### Impact

All services with `DynamicUser=yes` fail on restart:
- **kea-dhcp4-server** — DHCP down, no IP address assignment
- **kea-dhcp-ddns-server** — Dynamic DNS updates down
- **adguardhome** — DNS ad-blocking down

On routy (the network gateway), this means total network outage for all clients.

### Timeline

| Time | Event |
|------|-------|
| 03:00 | nixos-upgrade.service starts, pulls latest flake |
| 03:03 | Build completes, `switch-to-configuration switch` begins |
| 03:03 | systemd-boot updated 258.2 → 258.3 |
| 03:03 | Services stopped, systemd restarted, services restarted |
| 03:03 | Kea, AdGuardHome fail with RUNTIME_DIRECTORY permission error |
| 03:03 | `switch-to-configuration` reports failure (exit status 4) |
| 03:03–06:25 | Kea crash-loops (2316 restart attempts), network down |
| 06:25 | Manual reboot (ONT power cycle) |
| 06:47 | routy boots cleanly, all services start, network restored |

### Fix

A boot-time workaround has been added to routy's NixOS configuration. It runs a
oneshot service early in boot that chmods `/run/private` from 0710 to 0700, so
that any subsequent service restart passes the `mkdir_safe` permission check.

See `nixos/hosts/routy/fixup-run-private.nix`.

### Manual Recovery

If the workaround is not deployed and Kea is crash-looping:

```bash
sudo chmod 0700 /run/private
sudo systemctl restart kea-dhcp4-server
sudo systemctl restart kea-dhcp-ddns-server
```

Or simply reboot the machine — the initial boot start works fine.

### Removal Criteria

This workaround should be removable once either:
- systemd fixes the inconsistency between creation mode (0710) and mkdir_safe
  validation mode (0700)
- NixOS adds a general workaround in `switch-to-configuration`

### Affected Hosts

Any host running systemd 258.3 with `DynamicUser=yes` services is affected, but
routy is the most critical because DHCP/DNS failure causes a network-wide outage.
Other hosts would experience service-specific failures but no cascading impact.

### References

- systemd `mkdirat_safe_internal()`: https://github.com/systemd/systemd/blob/main/src/basic/mkdir.c
- systemd Dynamic Users: https://0pointer.net/blog/dynamic-users-with-systemd.html
