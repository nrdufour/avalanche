# VPN egress: WireGuard tunnel to Hetzner VPS + microsocks SOCKS5 proxy
# K8s pods connect to 10.1.0.1:1080 → microsocks → WireGuard → VPS → internet
# See docs/architecture/network/vpn-egress-socks-proxy.md
#
# VPS endpoint and keys are read from SOPS so reprovisioning the VPS only
# requires updating secrets + redeploying routy (no nix file edits).
{ config, pkgs, ... }:
let
  ipr = "${pkgs.iproute2}/bin/ip";
in
{
  # --- SOPS template: generate wg-egress.conf from secrets ---
  sops.templates."wg-egress.conf" = {
    content = ''
      [Interface]
      PrivateKey = ${config.sops.placeholder."wireguard/egress-private-key"}

      [Peer]
      PublicKey = ${config.sops.placeholder."wireguard/egress-server-pubkey"}
      Endpoint = ${config.sops.placeholder."wireguard/egress-server-endpoint"}
      AllowedIPs = 0.0.0.0/0
      PersistentKeepalive = 25
    '';
    owner = "root";
    group = "systemd-network";
    mode = "0640";
  };

  # --- WireGuard interface via systemd service ---
  systemd.services.wg-egress = {
    description = "WireGuard VPN egress tunnel";
    after = [ "network-online.target" "sops-nix.service" ];
    wants = [ "network-online.target" "sops-nix.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.wireguard-tools pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "wg-egress-up" ''
        set -euo pipefail
        # Clean up stale interface if present
        ip link del wg-egress 2>/dev/null || true
        ip link add wg-egress type wireguard
        wg setconf wg-egress ${config.sops.templates."wg-egress.conf".path}
        ip addr add 10.100.0.2/24 dev wg-egress
        ip link set wg-egress up

        # VPS endpoint route is managed by wg-egress-route.service below
        # (needs to track WAN gateway changes from DHCP).
      '';
      ExecStop = pkgs.writeShellScript "wg-egress-down" ''
        ip link del wg-egress || true
      '';
    };
  };

  # --- microsocks SOCKS5 proxy ---
  users.users.microsocks = { isSystemUser = true; group = "microsocks"; uid = 400; };
  users.groups.microsocks = { gid = 400; };

  systemd.services.microsocks-egress = {
    description = "SOCKS5 proxy for VPN egress";
    after = [ "wg-egress.service" ];
    wants = [ "wg-egress.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.microsocks}/bin/microsocks -i 10.1.0.1 -p 1080";
      Restart = "always";
      RestartSec = 5;
      # Explicit user, not DynamicUser (avoids /run/private systemd bug on routy)
      User = "microsocks";
      Group = "microsocks";
    };
  };

  # --- Prometheus WireGuard exporter (port 9586) ---
  systemd.services.prometheus-wireguard-exporter = {
    description = "Prometheus WireGuard exporter";
    after = [ "wg-egress.service" ];
    wants = [ "wg-egress.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.wireguard-tools ];
    serviceConfig = {
      ExecStart = "${pkgs.prometheus-wireguard-exporter}/bin/prometheus_wireguard_exporter -i wg-egress -d true -r true";
      Restart = "always";
      RestartSec = 10;
      # Runs as root — wg show requires CAP_NET_ADMIN and the exporter
      # shells out to `wg`, so ambient caps on a dynamic user aren't enough.
    };
  };

  # --- VPS endpoint route (prevents routing loop) ---
  # WireGuard copies the fwmark from inner to outer packets, so without a
  # direct route for the VPS endpoint, outer UDP packets loop back into the
  # tunnel via table 51820. This service waits for the WAN DHCP gateway and
  # keeps the route updated if the gateway changes (ISP rotates IPs on reboot).
  systemd.services.wg-egress-route = {
    description = "VPS endpoint route for WireGuard egress";
    after = [ "wg-egress.service" ];
    requires = [ "wg-egress.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStart = pkgs.writeShellScript "wg-egress-route" ''
        set -euo pipefail
        VPS_IP=$(grep -oP 'Endpoint\s*=\s*\K[^:]+' ${config.sops.templates."wg-egress.conf".path})

        # Wait for WAN default gateway (DHCP may not be ready at boot)
        GATEWAY=""
        while [ -z "$GATEWAY" ]; do
          GATEWAY=$(ip route show default | awk '{print $3; exit}')
          [ -z "$GATEWAY" ] && sleep 2
        done
        ip route replace "$VPS_IP" via "$GATEWAY" table 51820

        # Monitor for gateway changes (DHCP renew / IP rotation)
        while true; do
          sleep 30
          NEW_GW=$(ip route show default | awk '{print $3; exit}')
          if [ -n "$NEW_GW" ] && [ "$NEW_GW" != "$GATEWAY" ]; then
            ip route replace "$VPS_IP" via "$NEW_GW" table 51820
            GATEWAY="$NEW_GW"
          fi
        done
      '';
    };
  };

  # --- Declarative routing policy: fwmark 51820 → table 51820 ---
  # Managed by systemd-networkd so it survives tailscaled ip-rule flushes.
  systemd.network.networks."40-wg-egress" = {
    matchConfig.Name = "wg-egress";
    linkConfig.RequiredForOnline = "no";
    # Keep the VPS endpoint route set by the wg-egress ExecStart script
    # (it depends on a SOPS secret so it can't be declared here).
    networkConfig.KeepConfiguration = "static";
    routingPolicyRules = [{
      FirewallMark = 51820;
      Table = 51820;
    }];
    routes = [
      # Default route through the tunnel
      { Gateway = "10.100.0.1"; Table = 51820; }
    ];
  };

  # --- nftables: mark microsocks traffic for WireGuard routing ---
  networking.nftables.tables.mangle-egress = {
    family = "inet";
    content = ''
      chain output {
        type route hook output priority mangle;
        meta skuid 400 meta mark set 0x0000ca6c
      }
    '';
  };

  # --- nftables: SNAT traffic entering the WireGuard tunnel ---
  # Without this, packets enter the tunnel with routy's WAN IP as source,
  # but the VPS AllowedIPs only accepts 10.100.0.2 — silently dropping them.
  networking.nftables.tables.nat-egress = {
    family = "ip";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "wg-egress" masquerade
      }
    '';
  };
}
