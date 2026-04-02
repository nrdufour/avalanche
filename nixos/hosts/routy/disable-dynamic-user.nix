# Disable DynamicUser for network-critical services on routy
#
# The NixOS modules for kea and adguardhome hardcode DynamicUser=true, which
# makes these services depend on /run/private/. After NixOS live upgrades
# (switch-to-configuration), systemd 258.x can leave /run/private in a state
# where mkdir_safe() rejects it (mode 0710 vs expected 0700), causing these
# services to crash-loop. On routy (the network gateway), this means DHCP and
# DNS go down — a network-wide outage.
#
# Fix: use static users instead of DynamicUser. This eliminates the
# /run/private dependency entirely.
#
# Incidents: 2026-02-08, 2026-04-02
{ lib, pkgs, ... }: {

  # --- Static user for AdGuardHome ---
  # (kea user/group already created in kea/ddns.nix)
  users.users.adguardhome = {
    isSystemUser = true;
    group = "adguardhome";
  };
  users.groups.adguardhome = { };

  # --- Disable DynamicUser on all three services ---
  systemd.services.kea-dhcp4-server.serviceConfig.DynamicUser = lib.mkForce false;
  systemd.services.kea-dhcp-ddns-server.serviceConfig.DynamicUser = lib.mkForce false;
  systemd.services.adguardhome.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "adguardhome";
    Group = "adguardhome";
  };

}
