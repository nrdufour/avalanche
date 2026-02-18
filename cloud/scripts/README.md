# Hetzner Cloud VPS Management Scripts

This directory contains scripts to manage VPS instances on Hetzner Cloud for network egress.

## VPS Types

### WireGuard Exit Node (Active)

A WireGuard VPN exit point used by routy's SOCKS5 proxy. K8s pods route traffic through `routy:1080` → WireGuard tunnel → VPS → internet.

**Scripts:**
- `generate-wg-keys.sh` — One-time: generate WireGuard keypairs, store in SOPS
- `provision-wg-exit.sh` — Create VPS (reads keys from SOPS)
- `set-wg-endpoint.sh` — Record VPS IP in routy's SOPS secrets
- `deprovision-wg-exit.sh` — Destroy VPS (keys preserved in SOPS)
- `cloud-init-wireguard.yaml.template` — Cloud-init template for WireGuard VPS

**Architecture:** See `docs/architecture/network/vpn-egress-socks-proxy.md`

### Tailscale Exit Node (Legacy)

Previous approach using Tailscale as exit node. Superseded by WireGuard due to [tailscale/tailscale#15173](https://github.com/tailscale/tailscale/issues/15173).

**Scripts:**
- `provision-exit-node.sh` — Create Tailscale exit node VPS
- `deprovision-exit-node.sh` — Destroy Tailscale VPS
- `cloud-init.yaml.template` — Cloud-init template for Tailscale VPS

### Shared Scripts

- `update-home-ip.sh` — Update Hetzner firewall SSH rule when home IP changes. Set `FIREWALL_NAME` env var to target the correct firewall (default: `tailscale-exit-fw`).

## Prerequisites

1. **Hetzner Cloud CLI (`hcloud`)**
   - Already installed via NixOS configuration
   - Configure with: `hcloud context create`
   - Set up API token from: https://console.hetzner.cloud/

2. **SOPS with Age**
   - Already configured in avalanche repository
   - Secrets encrypted with your Age keys

3. **WireGuard tools** (for `generate-wg-keys.sh` only)
   - `wg genkey` / `wg pubkey` used during key generation
   - Available in the dev shell

## WireGuard Exit Node Usage

### Initial Setup (one-time)

Generate WireGuard keypairs and store in SOPS:

```bash
./generate-wg-keys.sh
```

Keys are stored in both `secrets/cloud/` and `secrets/routy/` SOPS files. Safe to re-run (asks before overwriting).

### Provision VPS

```bash
./provision-wg-exit.sh
```

Reads keys from SOPS, creates the VPS. Does NOT modify any secrets files.

**Default Configuration:**
- Server name: `wg-exit`
- Server type: `cax11` (2 vCPU ARM, 4 GB RAM, 40 GB SSD) — ~€3.29/month
- Location: `nbg1` (Nuremberg, Germany)
- Image: `ubuntu-24.04`

**Customize with environment variables:**

```bash
SERVER_NAME=wg-exit-2 SERVER_TYPE=cpx21 LOCATION=hel1 ./provision-wg-exit.sh
```

### After Provisioning

1. **Wait 1-2 minutes** for cloud-init to complete
2. **Verify VPS:** `ssh root@<VPS_IP> 'wg show'`
3. **Set endpoint:** `./set-wg-endpoint.sh <VPS_IP>` (or omit IP to auto-detect from hcloud)
4. **Deploy routy:** `just nix deploy routy`
5. **Verify tunnel:** `ssh routy.internal bash -c 'wg show wg-egress'`
6. **Test proxy:** `curl --socks5 10.1.0.1:1080 https://ifconfig.me` (should show VPS IP)

### Update Home IP

```bash
FIREWALL_NAME=wg-exit-fw ./update-home-ip.sh
```

### Deprovision

```bash
./deprovision-wg-exit.sh
```

WireGuard keys are preserved in SOPS — reprovisioning will reuse them automatically.

### Reprovisioning

Keys are stable in SOPS. To reprovision:

```bash
./deprovision-wg-exit.sh
./provision-wg-exit.sh
./set-wg-endpoint.sh          # auto-detects IP from hcloud
just nix deploy routy
```

## Cost

~€3.29/month (~$3.60/month)

- CAX11: €3.29/month — 2 vCPU ARM, 4 GB RAM, 40 GB disk
- Traffic: 20 TB included
- Billed hourly (only pay while server exists)

## Security

### Firewall Configuration (WireGuard VPS)

Hetzner Cloud Firewall:
- **SSH (port 22/tcp):** Only from home IP
- **WireGuard (port 51820/udp):** From anywhere (encrypted by design)
- **ICMP:** From anywhere

UFW on VPS (secondary layer):
- SSH: allowed
- WireGuard: allowed

### Secrets

- WireGuard keypairs stored in `secrets/cloud/secrets.sops.yaml` (SOPS + Age)
- routy's private key also stored in `secrets/routy/secrets.sops.yaml`
- Generated cloud-init files (containing unencrypted keys) are auto-cleaned via trap

### SSH Access

- SSH key-only authentication
- Restricted to home IP via Hetzner firewall

## Files

| File | Purpose |
|------|---------|
| `generate-wg-keys.sh` | Generate WireGuard keypairs (one-time) |
| `provision-wg-exit.sh` | Provision WireGuard exit node VPS |
| `set-wg-endpoint.sh` | Record VPS IP in routy's SOPS secrets |
| `deprovision-wg-exit.sh` | Destroy WireGuard VPS |
| `cloud-init-wireguard.yaml.template` | Cloud-init for WireGuard VPS |
| `provision-exit-node.sh` | Provision Tailscale exit node (legacy) |
| `deprovision-exit-node.sh` | Destroy Tailscale VPS (legacy) |
| `cloud-init.yaml.template` | Cloud-init for Tailscale VPS (legacy) |
| `update-home-ip.sh` | Update firewall SSH rule |

## Troubleshooting

### Can't SSH to VPS

```bash
# Check if your IP changed
curl https://api.ipify.org

# Update firewall
FIREWALL_NAME=wg-exit-fw ./update-home-ip.sh
```

### WireGuard not working on VPS

```bash
ssh root@<VPS_IP>

# Check cloud-init completed
cat /root/wireguard-setup.log

# Check WireGuard
wg show

# Check IP forwarding
sysctl net.ipv4.ip_forward

# Check masquerade
iptables -t nat -L POSTROUTING -v
```

## References

- [Hetzner Cloud Docs](https://docs.hetzner.com/cloud/)
- [WireGuard Documentation](https://www.wireguard.com/)
- [Cloud-init Documentation](https://cloudinit.readthedocs.io/)
- Architecture: `docs/architecture/network/vpn-egress-socks-proxy.md`
