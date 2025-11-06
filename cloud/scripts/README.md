# Hetzner Cloud VPS Management Scripts

This directory contains scripts to manage a Tailscale exit node VPS on Hetzner Cloud.

## Overview

These scripts automate the provisioning, management, and deprovisioning of a VPS configured as a Tailscale exit node. This is used to protect services like the IRC bot from exposing the home IP address.

## Prerequisites

1. **Hetzner Cloud CLI (`hcloud`)**
   - Already installed via NixOS configuration
   - Configure with: `hcloud context create`
   - Set up API token from: https://console.hetzner.cloud/

2. **Tailscale Auth Key**
   - Get from: https://login.tailscale.com/admin/settings/keys
   - Recommended: Create a **reusable key** that doesn't expire
   - Store in SOPS-encrypted file: `secrets/cloud/secrets.sops.yaml`

3. **SOPS with Age**
   - Already configured in avalanche repository
   - Secrets encrypted with your Age keys

## Setup

### 1. Add Tailscale Auth Key to SOPS

Edit the encrypted secrets file:

```bash
sops ../../secrets/cloud/secrets.sops.yaml
```

Replace `YOUR_TAILSCALE_AUTH_KEY_HERE` with your actual Tailscale auth key:

```yaml
tailscale_auth_key: tskey-auth-xxxxxxxxxxxxxxxxxxxx
```

Save and exit. SOPS will automatically re-encrypt the file.

## Usage

### Provision VPS

Create a new Hetzner VPS configured as a Tailscale exit node:

```bash
./provision-exit-node.sh
```

This script will:
1. Detect your home IP address (with confirmation)
2. Create a Hetzner Cloud Firewall restricting SSH to your home IP
3. Upload your SSH key to Hetzner (if not already present)
4. Decrypt the Tailscale auth key from SOPS
5. Generate cloud-init configuration with the auth key
6. Create the VPS (CX22, €4.51/month, Nuremberg)
7. Attach the firewall to the VPS
8. Clean up the temporary cloud-init file

**Default Configuration:**
- Server name: `tailscale-exit`
- Server type: `cpx11` (2 vCPU, 2 GB RAM, 40 GB SSD) - **New generation**
- Location: `nbg1` (Nuremberg, Germany)
- Image: `ubuntu-24.04`
- Firewall: SSH (port 22) from home IP only, ICMP allowed

**Note:** Previously used `cx22` but that server type is deprecated (end of year 2025). The `cpx11` is the new generation replacement.

**Customize with environment variables:**

```bash
SERVER_NAME=my-exit-node SERVER_TYPE=cpx21 LOCATION=hel1 ./provision-exit-node.sh
```

### After Provisioning

1. **Wait 1-2 minutes** for cloud-init to complete Tailscale setup

2. **Approve the exit node** in Tailscale admin panel:
   - Go to: https://login.tailscale.com/admin/machines
   - Find device named `tailscale-exit`
   - Click the three dots menu
   - Select "Edit route settings"
   - Enable "Use as exit node"

3. **Verify it's working:**

```bash
# SSH to the server
ssh root@<SERVER_IP>

# Check Tailscale status
tailscale status

# You should see "Exit node: advertised"
```

### Update Home IP

If your home IP address changes, update the firewall rule:

```bash
./update-home-ip.sh
```

This script will:
1. Detect your current public IP
2. Show the current and new IP addresses
3. Update the firewall rule to allow SSH from the new IP

### Deprovision VPS

Destroy the VPS and clean up resources:

```bash
./deprovision-exit-node.sh
```

This script will:
1. Show details of resources to be deleted
2. Ask for confirmation
3. Delete the VPS
4. Delete the firewall (if not used by other servers)
5. Remind you to remove the device from Tailscale admin panel

**Note:** Remember to manually remove the device from Tailscale admin panel after deprovisioning.

## Cost

**Current configuration:** ~€3.85/month (~$4.20/month)

- CPX11: €3.85/month (€0.0063/hour) - 2 vCPU, 2 GB RAM, 40 GB disk
- Traffic: Unlimited (20 TB included)

**Alternative options:**
- `SERVER_TYPE=cpx21` for €7.00/month (3 vCPU, 4 GB RAM) - if you need more resources
- You're only charged for the time the server exists (billed hourly)

**Note:** The old CX series (cx11, cx22, etc.) is deprecated and will be removed end of 2025. Use CPX series instead.

## Security

### Firewall Configuration

The Hetzner Cloud Firewall restricts access to:
- **SSH (port 22):** Only from your home IP address
- **ICMP:** Allowed from anywhere (for ping)
- **Tailscale (port 41641/udp):** Implicitly allowed by Tailscale itself

The VPS also has UFW (Uncomplicated Firewall) configured as a secondary layer:
- SSH: allowed
- Tailscale: allowed

### Secrets Management

- Tailscale auth key is stored encrypted in `secrets/cloud/secrets.sops.yaml` using SOPS with Age
- The auth key is only decrypted during provisioning
- Generated cloud-init files (containing unencrypted secrets) are automatically cleaned up
- A trap is set to clean up the cloud-init file even if the script exits early

### SSH Access

- Only your SSH public key is added to the VPS
- SSH is restricted to your home IP via firewall
- Root login is enabled (standard for VPS, accessed via SSH key only)

## Files

- **`provision-exit-node.sh`** - Main provisioning script
- **`deprovision-exit-node.sh`** - Deprovisioning/cleanup script
- **`update-home-ip.sh`** - Update firewall when home IP changes
- **`cloud-init.yaml.template`** - Template for cloud-init configuration
- **`cloud-init.yaml`** - Generated file (temporary, auto-deleted, contains secrets)

## Troubleshooting

### Script says auth key not set

```bash
# Edit the secrets file
sops ../../secrets/cloud/secrets.sops.yaml

# Make sure it contains:
tailscale_auth_key: tskey-auth-xxxxxxxxxxxxxxxxxxxx
```

### Can't SSH to VPS

```bash
# Check if your IP changed
curl https://api.ipify.org

# Update firewall
./update-home-ip.sh
```

### Tailscale not connecting

```bash
# SSH to VPS
ssh root@<SERVER_IP>

# Check cloud-init logs
tail -f /var/log/cloud-init-output.log

# Check Tailscale status
tailscale status

# Check Tailscale logs
journalctl -u tailscaled -f
```

### VPS not showing as exit node

1. Make sure you approved it in Tailscale admin panel
2. Check that IP forwarding is enabled:
   ```bash
   ssh root@<SERVER_IP> 'sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding'
   # Both should be 1
   ```

## Integration with Kubernetes

Once the exit node is approved, you can use it in Kubernetes with the Tailscale operator:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: marmithon-irc-bot
  annotations:
    tailscale.com/proxy: "true"
    tailscale.com/tags: "tag:k8s"
    tailscale.com/use-exit-node: "tailscale-exit"
spec:
  # ... your pod spec
```

See Phase 2 of the avalanche-plan.md for full Kubernetes integration details.

## References

- Hetzner Cloud Docs: https://docs.hetzner.com/cloud/
- Tailscale Exit Nodes: https://tailscale.com/kb/1103/exit-nodes
- Cloud-init Documentation: https://cloudinit.readthedocs.io/
