# Workaround: Fix /run/private permissions at boot
#
# Problem:
#   systemd 258.3 creates /run/private with mode 0710 at boot. Services that
#   use DynamicUser=yes (like kea-dhcp4-server) start fine on initial boot,
#   but any subsequent restart fails because systemd's mkdir_safe() validates
#   the existing /run/private against mode 0700 and rejects 0710 as "too
#   permissive" (exit status 233/RUNTIME_DIRECTORY).
#
#   On routy (the network gateway), a Kea restart failure means DHCP goes
#   down, causing a network-wide outage. This was discovered during the
#   2026-02-08 incident where a nixos-upgrade restarted Kea and it entered
#   a crash loop for 3.5 hours.
#
# Fix:
#   chmod /run/private to 0700 once at boot, after systemd creates it (as
#   0710) but early enough that no DynamicUser service has been restarted
#   yet. This makes mkdir_safe()'s permission check pass for all subsequent
#   service restarts during the boot session.
#
# Why this is safe:
#   - /run/private is a root-owned tmpfs boundary directory for DynamicUser
#     isolation; removing group-execute does not affect service functionality
#   - The initial boot start of services works regardless (different code path)
#   - Once set to 0700, it stays 0700 for the entire boot session
#   - systemd recreates /run/private fresh on each boot, so this is not
#     persistent — it runs every boot
#
# Incident: 2026-02-08 — see docs/troubleshooting/systemd-run-private-upgrade.md
#
# TODO: Remove this workaround once either:
#   - systemd fixes the inconsistency between creation mode (0710) and
#     mkdir_safe validation mode (0700)
#   - NixOS adds a general fix in switch-to-configuration
{ ... }: {
  systemd.services.fixup-run-private = {
    description = "Fix /run/private permissions for DynamicUser services";

    # Start early in boot, after local-fs.target (so /run is mounted)
    # but before any DynamicUser service might be restarted.
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
