# Workaround: Fix /run/private permissions at boot (defensive)
#
# Problem:
#   When systemd is upgraded in-place via switch-to-configuration (e.g. during
#   nixos-upgrade), the new systemd daemon runs with old runtime state. In this
#   mixed state, restarting DynamicUser=yes services (like kea-dhcp4-server)
#   fails because systemd's mkdir_safe() rejects the existing /run/private
#   directory (mode 0710) as "too permissive" (expects 0700), exit status
#   233/RUNTIME_DIRECTORY.
#
#   On a clean boot, the issue does not reproduce — services start and restart
#   fine even with /run/private at 0710. The bug is specific to live systemd
#   daemon upgrades creating a mixed old-state/new-binary condition.
#
#   On routy (the network gateway), a Kea restart failure means DHCP goes
#   down, causing a network-wide outage. This was discovered during the
#   2026-02-08 incident where a nixos-upgrade upgraded systemd 258.2 → 258.3,
#   restarted Kea, and it entered a crash loop for 3.5 hours.
#
# Fix:
#   chmod /run/private to 0700 at boot. This is defensive insurance — the
#   chmod is harmless on a clean boot (where restarts already work), and it
#   protects against the case where switch-to-configuration later upgrades
#   systemd in-place and restarts DynamicUser services within the same boot
#   session.
#
# Why this is safe:
#   - /run/private is a root-owned tmpfs boundary directory for DynamicUser
#     isolation; removing group-execute does not affect service functionality
#   - systemd recreates /run/private fresh on each boot, so this is not
#     persistent
#
# Incident: 2026-02-08 — see docs/troubleshooting/systemd-run-private-upgrade.md
#
# TODO: Remove this workaround once either:
#   - systemd fixes the inconsistency between creation mode (0710) and
#     mkdir_safe validation mode (0700) during in-place daemon upgrades
#   - NixOS adds a general fix in switch-to-configuration
{ ... }: {
  systemd.services.fixup-run-private = {
    description = "Fix /run/private permissions for DynamicUser services";

    # Start early in boot, after local-fs.target (so /run is mounted).
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "kea-dhcp4-server.service" "kea-dhcp-ddns-server.service" "adguardhome.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # If /run/private exists with the wrong mode, fix it.
      # If it doesn't exist yet, do nothing — systemd will create it
      # when the first DynamicUser service starts.
      ExecStart = "/bin/sh -c 'test -d /run/private && chmod 0700 /run/private || true'";
    };
  };
}
