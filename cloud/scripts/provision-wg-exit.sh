#!/usr/bin/env bash
set -euo pipefail

# Provisions a Hetzner VPS as a WireGuard exit node.
# Prerequisites: run generate-wg-keys.sh first to create keypairs in SOPS.
# After provisioning: run set-wg-endpoint.sh to record the VPS IP, then deploy routy.

# Configuration
SERVER_NAME="${SERVER_NAME:-wg-exit}"
FIREWALL_NAME="${FIREWALL_NAME:-${SERVER_NAME}-fw}"
SERVER_TYPE="${SERVER_TYPE:-cax11}"  # ARM, €3.29/month
LOCATION="${LOCATION:-nbg1}"         # Nuremberg, Germany
IMAGE="${IMAGE:-ubuntu-24.04}"
SSH_KEY_NAME="${SSH_KEY_NAME:-avalanche}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

# Prerequisites
if ! hcloud context list &>/dev/null; then
    log_error "hcloud is not configured. Run 'hcloud context create' first."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_INIT_TEMPLATE="${SCRIPT_DIR}/cloud-init-wireguard.yaml.template"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init-wireguard.yaml"
SECRETS_FILE="${REPO_ROOT}/secrets/cloud/secrets.sops.yaml"

for f in "$CLOUD_INIT_TEMPLATE" "$SECRETS_FILE"; do
    if [[ ! -f "$f" ]]; then
        log_error "Required file not found: $f"
        exit 1
    fi
done

log_info "Checking if server '$SERVER_NAME' already exists..."
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    log_error "Server '$SERVER_NAME' already exists!"
    log_info "Either delete it first or use: ./deprovision-wg-exit.sh"
    exit 1
fi

# --- Read keys from SOPS ---
log_step "Reading WireGuard keys from SOPS..."
CLOUD_DECRYPTED=$(sops -d "$SECRETS_FILE")

WG_SERVER_PRIVKEY=$(echo "$CLOUD_DECRYPTED" | grep "wg_server_private_key:" | awk '{print $2}')
WG_ROUTY_PUBKEY=$(echo "$CLOUD_DECRYPTED" | grep "wg_routy_public_key:" | awk '{print $2}')

if [[ -z "$WG_SERVER_PRIVKEY" || -z "$WG_ROUTY_PUBKEY" ]]; then
    log_error "WireGuard keys not found in SOPS."
    log_info "Run ./generate-wg-keys.sh first."
    exit 1
fi

WG_SERVER_PUBKEY=$(echo "$WG_SERVER_PRIVKEY" | wg pubkey)
log_info "Keys loaded (server pubkey: ${WG_SERVER_PUBKEY:0:20}...)"

# --- Generate cloud-init ---
log_step "Generating cloud-init configuration..."
sed \
    -e "s|__WG_SERVER_PRIVATE_KEY__|${WG_SERVER_PRIVKEY}|g" \
    -e "s|__WG_ROUTY_PUBLIC_KEY__|${WG_ROUTY_PUBKEY}|g" \
    "$CLOUD_INIT_TEMPLATE" > "$CLOUD_INIT_FILE"

trap 'rm -f "$CLOUD_INIT_FILE"' EXIT

# --- Detect home IP ---
log_step "Detecting home IP address..."
HOME_IP=$(curl -s https://api.ipify.org)
if [[ -z "$HOME_IP" ]]; then
    log_error "Failed to detect home IP address"
    read -rp "Please enter your home IP address: " HOME_IP
fi
log_info "Home IP: $HOME_IP"

read -rp "$(echo -e "${YELLOW}Is this your correct home IP? [Y/n]:${NC} ")" -n 1 REPLY
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    read -rp "Enter your home IP address: " HOME_IP
fi

# --- SSH key ---
log_step "Checking SSH key..."
SSH_KEY_TO_USE=""

if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
    SSH_KEY_TO_USE="$SSH_KEY_NAME"
    log_info "Using existing SSH key: $SSH_KEY_NAME"
else
    log_warn "SSH key '$SSH_KEY_NAME' not found in Hetzner."

    LOCAL_SSH_KEY=""
    if [[ -f ~/.ssh/id_ed25519.pub ]]; then
        LOCAL_SSH_KEY=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub ]]; then
        LOCAL_SSH_KEY=~/.ssh/id_rsa.pub
    else
        log_error "No SSH key found at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub"
        exit 1
    fi

    log_info "Uploading local SSH key ($LOCAL_SSH_KEY)..."
    if hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$LOCAL_SSH_KEY" 2>&1; then
        SSH_KEY_TO_USE="$SSH_KEY_NAME"
    else
        log_warn "SSH key content already exists in Hetzner with a different name"
        LOCAL_FINGERPRINT=$(ssh-keygen -E md5 -lf "$LOCAL_SSH_KEY" | awk '{print $2}' | sed 's/MD5://')
        EXISTING_KEY=$(hcloud ssh-key list -o columns=name,fingerprint | tail -n +2 | grep "$LOCAL_FINGERPRINT" | awk '{print $1}')

        if [[ -n "$EXISTING_KEY" ]]; then
            SSH_KEY_TO_USE="$EXISTING_KEY"
            log_info "Found existing SSH key: $EXISTING_KEY"
        else
            log_error "Could not find existing SSH key. Run: hcloud ssh-key list"
            exit 1
        fi
    fi
fi

# --- Firewall ---
log_step "Setting up firewall..."
if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
    log_warn "Firewall '$FIREWALL_NAME' already exists. Deleting and recreating..."

    APPLIED_TO=$(hcloud firewall describe "$FIREWALL_NAME" -o json 2>/dev/null | grep '"applied_to"' | grep -v '\[\]' || true)
    if [[ -n "$APPLIED_TO" ]]; then
        log_error "Firewall '$FIREWALL_NAME' is still attached to servers."
        log_info "Run './deprovision-wg-exit.sh' first."
        exit 1
    fi

    hcloud firewall delete "$FIREWALL_NAME" || { log_error "Failed to delete firewall"; exit 1; }
    log_info "Old firewall deleted"
fi

log_info "Creating firewall '$FIREWALL_NAME'..."
hcloud firewall create \
    --name "$FIREWALL_NAME" \
    --rules-file <(cat <<EOF
[
  {
    "direction": "in",
    "source_ips": ["${HOME_IP}/32"],
    "protocol": "tcp",
    "port": "22",
    "description": "SSH from home"
  },
  {
    "direction": "in",
    "source_ips": ["0.0.0.0/0", "::/0"],
    "protocol": "udp",
    "port": "51820",
    "description": "WireGuard"
  },
  {
    "direction": "in",
    "source_ips": ["0.0.0.0/0", "::/0"],
    "protocol": "icmp",
    "description": "Allow ICMP (ping)"
  }
]
EOF
)

# --- Create server ---
log_step "Creating server '$SERVER_NAME'..."
log_info "  Type: $SERVER_TYPE"
log_info "  Location: $LOCATION"
log_info "  Image: $IMAGE"
log_info "  SSH Key: $SSH_KEY_TO_USE"
log_info "  Firewall: $FIREWALL_NAME"

hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --location "$LOCATION" \
    --image "$IMAGE" \
    --ssh-key "$SSH_KEY_TO_USE" \
    --firewall "$FIREWALL_NAME" \
    --user-data-from-file "$CLOUD_INIT_FILE"

sleep 5

SERVER_IP=$(hcloud server ip "$SERVER_NAME")
SERVER_ID=$(hcloud server describe "$SERVER_NAME" -o json | grep -oP '"id":\s*\K\d+' | head -1)

rm -f "$CLOUD_INIT_FILE"

# --- Summary ---
log_info "Server created successfully!"
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}WireGuard Exit Node Details${NC}"
echo -e "${GREEN}================================${NC}"
echo "Server Name:       $SERVER_NAME"
echo "Server ID:         $SERVER_ID"
echo "Server IP:         $SERVER_IP"
echo "Firewall:          $FIREWALL_NAME"
echo "SSH Access:        ${HOME_IP}/32 only"
echo ""
echo "WireGuard Tunnel:"
echo "  VPS endpoint:    ${SERVER_IP}:51820"
echo "  VPS tunnel IP:   10.100.0.1"
echo "  routy tunnel IP: 10.100.0.2"
echo "  VPS public key:  $WG_SERVER_PUBKEY"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait 1-2 minutes for cloud-init to complete"
echo "2. Verify VPS:       ssh root@$SERVER_IP 'wg show'"
echo "3. Set endpoint:     ./set-wg-endpoint.sh $SERVER_IP"
echo "4. Deploy routy:     just nix deploy routy"
echo "5. Test proxy:       curl --socks5 10.1.0.1:1080 https://ifconfig.me"
echo ""
echo -e "${GREEN}To connect via SSH:${NC}"
echo "  ssh root@$SERVER_IP"
echo ""
echo -e "${YELLOW}If your home IP changes:${NC}"
echo "  FIREWALL_NAME=$FIREWALL_NAME ./update-home-ip.sh"
echo ""
echo -e "${RED}To destroy this server:${NC}"
echo "  ./deprovision-wg-exit.sh"
echo -e "${GREEN}================================${NC}"
