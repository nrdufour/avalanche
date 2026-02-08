# systemd /run/private Permission Mismatch on Live Upgrade

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

The failure is caused by systemd's `mkdirat_safe_internal()` function (in
`src/basic/mkdir.c`) rejecting `/run/private` during a **live systemd upgrade**:

```c
if ((st.st_mode & ~mode & 0777) != 0)
    // "Directory already exists, but has mode %04o that is too permissive
    //  (%04o was requested), refusing."
```

The group-execute bit (010) in the existing 0710 directory triggers a mismatch
against the requested mode 0700.

### When It Triggers (and When It Doesn't)

Extensive testing after the incident narrowed down the exact conditions:

- **Clean boot with systemd 258.3**: `/run/private` is created as 0710. All
  `DynamicUser=yes` services start fine. Manual `systemctl restart` also works
  fine. Manually recreating `/run/private` as 0710 and restarting services also
  works. The issue **cannot be reproduced on a clean boot**.

- **Live upgrade from 258.2 → 258.3 via `switch-to-configuration`**: The
  systemd daemon is restarted in-place, creating a mixed state where the new
  systemd binary runs with old runtime state. In this context, restarting
  `DynamicUser=yes` services fails with the RUNTIME_DIRECTORY permission error.

This means the bug is specifically a **live systemd daemon upgrade** issue —
the in-place daemon restart leaves systemd in a state where `mkdir_safe`
validation behaves differently than on a clean boot. After a reboot with the
same systemd version, the problem disappears.

### Impact

All services with `DynamicUser=yes` fail to start after a live systemd upgrade:
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
| 03:03 | Services stopped, systemd restarted in-place, services restarted |
| 03:03 | Kea, AdGuardHome fail with RUNTIME_DIRECTORY permission error |
| 03:03 | `switch-to-configuration` reports failure (exit status 4) |
| 03:03–06:25 | Kea crash-loops (2316 restart attempts), network down |
| 06:25 | Manual reboot (ONT power cycle) |
| 06:47 | routy boots cleanly, all services start, network restored |

### Fix

A boot-time workaround has been added to routy's NixOS configuration. It runs a
oneshot service early in boot that chmods `/run/private` from 0710 to 0700.

See `nixos/hosts/routy/fixup-run-private.nix`.

This is defensive insurance — the issue only manifests during live systemd
upgrades (not clean boots), but the chmod is harmless and protects against the
case where `switch-to-configuration` upgrades systemd in-place and restarts
`DynamicUser` services within the same boot session.

### Manual Recovery

If Kea is crash-looping due to this issue:

```bash
sudo chmod 0700 /run/private
sudo systemctl restart kea-dhcp4-server
sudo systemctl restart kea-dhcp-ddns-server
```

Or simply reboot the machine — a clean boot always works.

### Removal Criteria

This workaround should be removable once either:
- systemd fixes the inconsistency between creation mode (0710) and mkdir_safe
  validation mode (0700) during in-place daemon upgrades
- NixOS adds a general workaround in `switch-to-configuration`

### Affected Hosts

Any host running systemd 258.x with `DynamicUser=yes` services could be
affected during a live systemd upgrade. routy is the most critical because
DHCP/DNS failure causes a network-wide outage. Other hosts would experience
service-specific failures but no cascading impact.

### References

- systemd `mkdirat_safe_internal()`: https://github.com/systemd/systemd/blob/main/src/basic/mkdir.c
- systemd Dynamic Users: https://0pointer.net/blog/dynamic-users-with-systemd.html
