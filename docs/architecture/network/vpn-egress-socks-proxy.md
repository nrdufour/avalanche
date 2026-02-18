# VPN Egress via SOCKS5 Proxy (WireGuard + routy)

## Overview

Cluster-wide SOCKS5 proxy service for K8s pods that need to mask the home IP. Traffic flows through a WireGuard tunnel from routy (home gateway) to a Hetzner VPS, exiting with the VPS's public IP.

**Status**: Active (replaced gluetun sidecar pattern, Feb 2026)

## Problem Statement

K8s workloads (IRC bot, future services) need outbound IP masking. Previous approaches all failed:

| Approach | Problem |
|----------|---------|
| **Gluetun sidecar** | iptables/NAT/conntrack drops return traffic on idle TCP connections ([#2536](https://github.com/qdm12/gluetun/issues/2536), [#2504](https://github.com/qdm12/gluetun/issues/2504), [#2997](https://github.com/qdm12/gluetun/issues/2997)). Fatal for persistent IRC connections. |
| **Tailscale exit node in K8s** | [tailscale/tailscale#15173](https://github.com/tailscale/tailscale/issues/15173) blocks cluster-internal traffic when exit node is enabled. |
| **wireproxy/wghttp** | Unmaintained (22+ months stale), thin wrapper over wireguard-go. |
| **wiretap** | Client requires NET_ADMIN capability — same fundamental problem as gluetun. |
| **Tor** | IRCnet blocks Tor exit nodes. |

## Architecture

```
K8s pod (any namespace)
  → SOCKS5 proxy at 10.1.0.1:1080 (routy, lab0 interface)
    → WireGuard tunnel (routy wg-egress → Hetzner VPS wg0)
      → Internet (exit IP = VPS public IP)
```

### Components

1. **Hetzner VPS** (`wg-exit`): Minimal Ubuntu server running WireGuard. Accepts tunnel traffic from routy, NAT-masquerades it to the internet. Provisioned via `cloud/scripts/provision-wg-exit.sh`.

2. **routy WireGuard client** (`wg-egress` interface): Connects to VPS. Uses policy routing — only packets marked with fwmark 0xCA6C (51820) route through the tunnel. Normal routy traffic is unaffected.

3. **microsocks on routy**: Tiny SOCKS5 proxy (~100 lines C, in nixpkgs) bound to `10.1.0.1:1080` (lab0/LAN interface). Runs as dedicated `microsocks` user. nftables marks all microsocks-originated packets with fwmark 0xCA6C, routing them through WireGuard.

4. **K8s pods**: Connect to `10.1.0.1:1080` as a standard SOCKS5 proxy. No sidecars, no NET_ADMIN, no operator — just a proxy address.

### Why This Works for Idle Connections

The critical difference from gluetun: microsocks runs on routy (the gateway itself), not inside a container with synthetic iptables/NAT. The WireGuard tunnel is a kernel-level interface with `persistentKeepalive = 25`, so the tunnel stays alive even when the application-level TCP connection is idle. No conntrack entries to expire, no NAT state to lose.

## Network Flow Detail

```
1. Pod sends TCP to 10.1.0.1:1080 (SOCKS5 CONNECT to irc.server:6697)
2. microsocks accepts, opens outbound connection to irc.server:6697
3. nftables OUTPUT chain marks packet (skuid microsocks → fwmark 0xCA6C)
4. ip rule: fwmark 0xCA6C → table 51820
5. table 51820: default via 10.100.0.1 (VPS tunnel endpoint)
6. Packet enters wg-egress, encrypted via WireGuard to VPS
7. VPS decapsulates, MASQUERADE to eth0, packet reaches irc.server
8. Return traffic: irc.server → VPS eth0 → conntrack → wg0 → routy wg-egress → microsocks → pod
```

## How Pods Use It

Any pod can use the proxy — no namespace restrictions, no special labels.

### Go (marmithon IRC bot)

```go
import "golang.org/x/net/proxy"

dialer, _ := proxy.SOCKS5("tcp", "10.1.0.1:1080", nil, proxy.Direct)
conn, _ := dialer.Dial("tcp", "open.ircnet.io:6667")
// or with girc:
config.Dial = dialer.Dial
```

### curl (testing)

```bash
curl --socks5 10.1.0.1:1080 https://ifconfig.me
```

### Generic (environment variable)

Some tools respect `ALL_PROXY`:
```yaml
env:
  - name: ALL_PROXY
    value: "socks5://10.1.0.1:1080"
```

## VPS Lifecycle

### Initial Setup (one-time)

```bash
cd cloud/scripts
./generate-wg-keys.sh      # generate keypairs, store in SOPS
```

### Provision

```bash
cd cloud/scripts
./provision-wg-exit.sh     # create VPS (reads keys from SOPS)
./set-wg-endpoint.sh       # record VPS IP in routy's secrets
just nix deploy routy      # deploy WireGuard + microsocks to routy
```

### Update Home IP

```bash
cd cloud/scripts
FIREWALL_NAME=wg-exit-fw ./update-home-ip.sh
```

### Deprovision

```bash
cd cloud/scripts
./deprovision-wg-exit.sh
```

### Cost

~€3.79/month (Hetzner CAX11: 2 vCPU ARM, 4 GB RAM, 40 GB SSD, 20 TB traffic).

## Files

| File | Purpose |
|------|---------|
| `cloud/scripts/generate-wg-keys.sh` | One-time: generate keypairs, store in SOPS |
| `cloud/scripts/cloud-init-wireguard.yaml.template` | Cloud-init for WireGuard VPS |
| `cloud/scripts/provision-wg-exit.sh` | Create VPS (reads keys from SOPS) |
| `cloud/scripts/set-wg-endpoint.sh` | Record VPS IP in routy secrets |
| `cloud/scripts/deprovision-wg-exit.sh` | Destroy VPS |
| `nixos/hosts/routy/vpn-egress.nix` | WireGuard + microsocks + nftables + exporter on routy |
| `secrets/cloud/secrets.sops.yaml` | WireGuard keypairs (both sides) |
| `secrets/routy/secrets.sops.yaml` | routy's WireGuard private key, VPS pubkey + endpoint |
| `kubernetes/base/infra/observability/kube-prometheus-stack/scrapeconfig.yaml` | Prometheus scrape target for WireGuard exporter |
| `kubernetes/base/apps/home-automation/dashboards/wireguard.yaml` | Grafana dashboard ConfigMap |

## Extending to New Services

1. Configure the application to use SOCKS5 proxy at `10.1.0.1:1080`
2. That's it. No infrastructure changes needed.

If the application doesn't support SOCKS5 natively, options:
- Use a library (Go: `golang.org/x/net/proxy`, Python: `PySocks`, etc.)
- Use `tsocks` or `proxychains` as a wrapper (last resort)

## Troubleshooting

### WireGuard tunnel not up (routy)

```bash
# Check interface status
wg show wg-egress

# Should show: latest handshake within last 2 minutes
# If no handshake: check VPS is running, firewall allows UDP 51820

# Check routing table
ip route show table 51820
# Should show: default via 10.100.0.1

# Check ip rules
ip rule show | grep 51820
# Should show: fwmark 0xca6c lookup 51820
```

### microsocks not listening

```bash
ss -tlnp | grep 1080
# Should show microsocks listening on 10.1.0.1:1080

systemctl status microsocks-egress
journalctl -u microsocks-egress -f
```

### Proxy works but wrong IP

```bash
# Test from routy directly
curl --socks5 10.1.0.1:1080 https://ifconfig.me
# Should show VPS IP

# If showing home IP: check nftables mark rule
nft list table inet mangle-egress
# Should show: meta skuid 400 meta mark set 0x0000ca6c
```

### VPS WireGuard not responding

```bash
ssh root@<vps-ip>
wg show
# Check for handshake with routy peer

# Check masquerade
iptables -t nat -L POSTROUTING -v
# Should show MASQUERADE rule on eth0

# Check IP forwarding
sysctl net.ipv4.ip_forward
# Should be 1
```

## Comparison with Previous Approach (Gluetun)

| Aspect | Gluetun sidecar | WireGuard + microsocks |
|--------|-----------------|----------------------|
| Idle TCP connections | Broken (conntrack expiry) | Works (kernel WireGuard + keepalive) |
| Pod requirements | NET_ADMIN capability | None (just proxy address) |
| Per-pod overhead | Full gluetun container | Zero |
| Infrastructure cost | VPN subscription (~€5-10/mo) | Hetzner VPS (~€3.85/mo) |
| Control over exit IP | VPN provider chooses | Fixed, known VPS IP |
| Complexity | Per-pod sidecar config | One-time routy setup |

## Monitoring

- **Prometheus exporter**: `prometheus-wireguard-exporter` runs on routy (port 9586), scoped to `wg-egress` interface. Defined in `nixos/hosts/routy/vpn-egress.nix`.
- **Scrape config**: `kubernetes/base/infra/observability/kube-prometheus-stack/scrapeconfig.yaml` (target `10.0.0.1:9586`)
- **Grafana dashboard**: "WireGuard VPN Egress Tunnel" — auto-discovered via k8s-sidecar from `kubernetes/base/apps/home-automation/dashboards/wireguard.yaml`

Key metrics:
- `wireguard_latest_handshake_delay_seconds` — tunnel health (green < 150s, stale < 300s, down > 300s)
- `wireguard_sent_bytes_total` / `wireguard_received_bytes_total` — traffic counters
- `rate(wireguard_sent_bytes_total[5m])` — throughput

## Security Notes

- microsocks binds only to `10.1.0.1` (lab0/LAN), not `0.0.0.0` — only reachable from the LAN/K8s network
- No authentication on SOCKS5 (unnecessary — only LAN clients can reach it)
- VPS firewall restricts SSH to home IP only; WireGuard is open (encrypted by design)
- WireGuard private keys stored in SOPS, decrypted at deploy time

---

*Created: 2026-02-18*
*Replaces*: Gluetun sidecar pattern (see `vpn-egress-architecture.md` for historical reference)
