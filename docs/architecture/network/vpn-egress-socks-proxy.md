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

### Outbound (pod → internet)

```
1. Pod sends TCP to 10.1.0.1:1080 (SOCKS5 CONNECT to irc.server:6697)
2. microsocks (uid 400) accepts, opens outbound connection to irc.server:6697
3. nftables OUTPUT mangle chain: meta skuid 400 → mark 0xCA6C (decimal 51820)
4. Kernel re-routes: fwmark 0xCA6C matches ip rule → lookup table 51820
5. Table 51820: default via 10.100.0.1 → packet enters wg-egress interface
6. nftables POSTROUTING: masquerade on oifname "wg-egress" → SNAT to 10.100.0.2
7. WireGuard encrypts, sends outer UDP to VPS (78.47.76.161:51820)
8. VPS decapsulates, MASQUERADE to eth0 → packet reaches irc.server with VPS IP
```

### Return (internet → pod)

```
1. irc.server replies to VPS public IP
2. VPS conntrack reverse-NATs → wg0 tunnel → routy wg-egress
3. routy conntrack reverse-NATs (10.100.0.2 → routy WAN IP)
4. microsocks receives reply, forwards to pod via lab0 (10.1.0.x)
```

### Why microsocks replies stay on LAN

When microsocks sends a SYN-ACK back to the pod (10.1.0.x), that packet also
gets fwmarked 0xCA6C (because it's from uid 400). Without LAN routes in table
51820, the reply would be routed into the WireGuard tunnel instead of back to
the pod. The LAN routes (`10.0.0.0/24 dev lan0`, `10.1.0.0/24 dev lab0`, etc.)
in table 51820 are more specific than the default route, so reply traffic
correctly goes back to the LAN interface.

### Why the VPS endpoint route is needed

WireGuard copies the fwmark from inner packets to outer (encapsulated) UDP
packets. Without a direct route for the VPS IP in table 51820, the outer UDP
packet would match `default via 10.100.0.1` → re-enter wg-egress → infinite
loop. The `wg-egress-route` service adds `<VPS_IP> via <WAN_GW> dev wan0` to
table 51820, breaking the loop.

## Routing Table 51820

All routes managed declaratively by systemd-networkd, except the VPS endpoint
route which is managed by `wg-egress-route.service` (because the VPS IP is a
SOPS secret and the WAN gateway changes with DHCP).

```
default via 10.100.0.1 dev wg-egress    # tunnel default (40-wg-egress.network)
10.0.0.0/24 dev lan0                     # LAN reply path  (30-lan0.network)
10.1.0.0/24 dev lab0                     # K8s reply path  (30-lab0.network)
10.2.0.0/24 dev lab1                     # Lab1 reply path (30-lab1.network)
<VPS_IP> via <WAN_GW> dev wan0           # loop prevention (wg-egress-route.service)
```

## Systemd Services

| Service | Type | Purpose |
|---------|------|---------|
| `wg-egress` | oneshot | Creates wg-egress interface, applies WireGuard config, sets IP |
| `wg-egress-route` | simple (long-running) | Waits for WAN DHCP gateway, adds VPS endpoint route to table 51820, monitors for gateway changes every 30s |
| `microsocks-egress` | simple | SOCKS5 proxy on 10.1.0.1:1080 (uid 400) |
| `prometheus-wireguard-exporter` | simple | Metrics on port 9586 |

### Declarative config (systemd-networkd)

The ip rule (`fwmark 0xCA6C → table 51820`) is managed by systemd-networkd via
`40-wg-egress.network`, not by the wg-egress script. This is intentional —
tailscaled flushes ip rules on startup, so a script-added rule gets wiped.
systemd-networkd re-applies it when the interface is reconfigured.

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
| `nixos/hosts/routy/vpn-egress.nix` | WireGuard + microsocks + nftables + routing policy + exporter on routy |
| `nixos/hosts/routy/network/default.nix` | LAN interface routes in table 51820 (reply path for microsocks) |
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

### Quick health check

```bash
# From routy — does traffic exit via VPS?
curl -s --max-time 5 -x socks5h://10.1.0.1:1080 http://ifconfig.me
# Should print the VPS IP (78.47.76.161). If it prints the home IP or times out, see below.
```

### Check all components at once

```bash
# Services running?
systemctl is-active wg-egress wg-egress-route microsocks-egress

# IP rule present?
ip rule list | grep ca6c
# Expected: 32765: from all fwmark 0xca6c lookup 51820 proto static

# Routing table complete?
sudo ip route show table 51820
# Expected:
#   default via 10.100.0.1 dev wg-egress proto static onlink
#   10.0.0.0/24 dev lan0 proto static scope link
#   10.1.0.0/24 dev lab0 proto static scope link
#   10.2.0.0/24 dev lab1 proto static scope link
#   <VPS_IP> via <WAN_GW> dev wan0

# Tunnel alive?
ping -c 2 -W 2 -I wg-egress 10.100.0.1
# Expected: 0% packet loss, ~100ms
```

### Proxy times out (can't reach microsocks)

microsocks reply traffic is being routed into the tunnel instead of back to
the LAN. Check that table 51820 has LAN routes:

```bash
sudo ip route show table 51820 | grep -E 'lan0|lab0'
# Should show 10.0.0.0/24 dev lan0 and 10.1.0.0/24 dev lab0
# If missing: systemd-networkd didn't apply the routes — restart it
sudo systemctl restart systemd-networkd
```

### Proxy works but shows home IP (not VPS IP)

The fwmark routing isn't working. Check each step:

```bash
# 1. Is the ip rule present?
ip rule list | grep ca6c
# If missing: tailscaled may have flushed it. Restart systemd-networkd:
sudo systemctl restart systemd-networkd

# 2. Is the nftables mark rule active?
sudo nft list table inet mangle-egress
# Should show: meta skuid 400 meta mark set 0x0000ca6c
# If wrong UID: check microsocks user (id microsocks, should be uid 400)

# 3. Is table 51820 populated?
sudo ip route show table 51820
# If empty or missing default: restart wg-egress
sudo systemctl restart wg-egress
```

### SOCKS proxy times out to internet (tunnel broken)

```bash
# Is the VPS endpoint route present?
sudo ip route show table 51820 | grep <VPS_IP>
# If missing: the WAN gateway wasn't available when wg-egress-route started
sudo systemctl restart wg-egress-route

# Is the tunnel passing traffic?
ping -c 2 -W 2 -I wg-egress 10.100.0.1
# If 100% loss: check VPS is running, firewall allows UDP 51820
hcloud server list  # should show wg-exit as running

# Check WAN gateway changed? (ISP gives new IP on reboot)
ip route show default
# wg-egress-route monitors this every 30s, but check its logs:
journalctl -u wg-egress-route -b
```

### Stale IRC connections (marmithon "Too many host connections")

IRCnet has a per-IP global connection limit. Rapid reconnection (30s cycle)
creates overlapping connections that stack up past the limit.

```bash
# Check active connections through the proxy
sudo conntrack -L -p tcp --dport 6667
ss -tnp | grep 6667

# Kill stale connections
sudo conntrack -D -p tcp --dport 6667
sudo ss -K dst <stale_ip> dport = 6667

# If persistent: restart microsocks to drop all connections
sudo systemctl restart microsocks-egress
# Then scale down the bot and wait 2-3 minutes before scaling back up
```

### VPS SSH blocked (home IP changed)

The Hetzner firewall allowlists SSH by home IP. After an IP change:

```bash
# Check current home IP vs firewall rule
curl -s ifconfig.me
hcloud firewall describe wg-exit-fw

# Update the rule
hcloud firewall delete-rule wg-exit-fw --direction in --protocol tcp --port 22 \
  --source-ips <OLD_IP>/32 --description "SSH from home"
hcloud firewall add-rule wg-exit-fw --direction in --protocol tcp --port 22 \
  --source-ips <NEW_IP>/32 --description "SSH from home"
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

### Nuclear option: full restart sequence

```bash
sudo systemctl restart wg-egress        # recreates interface
sudo systemctl restart wg-egress-route   # re-adds VPS endpoint route
sudo systemctl restart microsocks-egress # drops all proxy connections
# Wait a few seconds, then test:
curl -s --max-time 5 -x socks5h://10.1.0.1:1080 http://ifconfig.me
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
