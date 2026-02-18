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

        # Policy routing: only marked packets use this tunnel
        ip rule add fwmark 51820 table 51820 || true
        ip route add default via 10.100.0.1 table 51820 || true

        # Copy connected routes so LAN reply traffic isn't tunneled.
        # Without this, microsocks' SYN-ACK to LAN clients gets fwmarked
        # and routed into the tunnel instead of back to the client.
        ip route show table main scope link | while read -r route; do
          ip route add $route table 51820 2>/dev/null || true
        done

        # Prevent routing loop: outer WireGuard UDP packets inherit the fwmark
        # from inner packets, so they'd loop back into the tunnel. Add a direct
        # route for the VPS endpoint via the WAN default gateway in table 51820.
        VPS_IP=$(${pkgs.gnugrep}/bin/grep -oP 'Endpoint\s*=\s*\K[^:]+' ${config.sops.templates."wg-egress.conf".path})
        GATEWAY=$(ip route show default | ${pkgs.gawk}/bin/awk '{print $3; exit}')
        if [ -n "$VPS_IP" ] && [ -n "$GATEWAY" ]; then
          ip route add "$VPS_IP" via "$GATEWAY" table 51820 || true
        fi
      '';
      ExecStop = pkgs.writeShellScript "wg-egress-down" ''
        ip link del wg-egress || true
        ip rule del fwmark 51820 table 51820 || true
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
