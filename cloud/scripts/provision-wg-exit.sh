#!/usr/bin/env bash
set -euo pipefail

# Configuration
SERVER_NAME="${SERVER_NAME:-wg-exit}"
FIREWALL_NAME="${FIREWALL_NAME:-${SERVER_NAME}-fw}"
SERVER_TYPE="${SERVER_TYPE:-cax11}"  # ARM, €3.29/month
LOCATION="${LOCATION:-nbg1}"         # Nuremberg, Germany
IMAGE="${IMAGE:-ubuntu-24.04}"
SSH_KEY_NAME="${SSH_KEY_NAME:-avalanche}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# Check prerequisites
if ! hcloud context list &>/dev/null; then
    log_error "hcloud is not configured. Run 'hcloud context create' first."
    exit 1
fi

if ! command -v wg &>/dev/null; then
    log_error "wireguard-tools not found. Install with: nix-shell -p wireguard-tools"
    exit 1
fi

if ! command -v sops &>/dev/null; then
    log_error "sops not found."
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_INIT_TEMPLATE="${SCRIPT_DIR}/cloud-init-wireguard.yaml.template"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init-wireguard.yaml"
SECRETS_FILE="${REPO_ROOT}/secrets/cloud/secrets.sops.yaml"

if [[ ! -f "$CLOUD_INIT_TEMPLATE" ]]; then
    log_error "cloud-init-wireguard.yaml.template not found at $CLOUD_INIT_TEMPLATE"
    exit 1
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
    log_error "Cloud secrets file not found at $SECRETS_FILE"
    exit 1
fi

log_info "Checking if server '$SERVER_NAME' already exists..."
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    log_error "Server '$SERVER_NAME' already exists!"
    log_info "Either delete it first or use: ./deprovision-wg-exit.sh"
    exit 1
fi

# --- WireGuard key generation / loading ---
log_step "Preparing WireGuard keys..."

# Check if keys already exist in SOPS (for reprovisioning)
EXISTING_SERVER_PRIVKEY=$(sops -d "$SECRETS_FILE" 2>/dev/null | grep "wg_server_private_key:" | awk '{print $2}' || true)
EXISTING_ROUTY_PRIVKEY=$(sops -d "$SECRETS_FILE" 2>/dev/null | grep "wg_routy_private_key:" | awk '{print $2}' || true)

if [[ -n "$EXISTING_SERVER_PRIVKEY" && "$EXISTING_SERVER_PRIVKEY" != "PLACEHOLDER" && \
      -n "$EXISTING_ROUTY_PRIVKEY" && "$EXISTING_ROUTY_PRIVKEY" != "PLACEHOLDER" ]]; then
    log_info "Found existing WireGuard keys in SOPS — reusing them"
    WG_SERVER_PRIVKEY="$EXISTING_SERVER_PRIVKEY"
    WG_ROUTY_PRIVKEY="$EXISTING_ROUTY_PRIVKEY"
    WG_SERVER_PUBKEY=$(echo "$WG_SERVER_PRIVKEY" | wg pubkey)
    WG_ROUTY_PUBKEY=$(echo "$WG_ROUTY_PRIVKEY" | wg pubkey)
else
    log_info "Generating new WireGuard keypairs..."
    WG_SERVER_PRIVKEY=$(wg genkey)
    WG_SERVER_PUBKEY=$(echo "$WG_SERVER_PRIVKEY" | wg pubkey)
    WG_ROUTY_PRIVKEY=$(wg genkey)
    WG_ROUTY_PUBKEY=$(echo "$WG_ROUTY_PRIVKEY" | wg pubkey)
    log_info "New keys generated"
fi

# --- Generate cloud-init ---
log_step "Generating cloud-init configuration..."

sed \
    -e "s|__WG_SERVER_PRIVATE_KEY__|${WG_SERVER_PRIVKEY}|g" \
    -e "s|__WG_ROUTY_PUBLIC_KEY__|${WG_ROUTY_PUBKEY}|g" \
    "$CLOUD_INIT_TEMPLATE" > "$CLOUD_INIT_FILE"

log_info "Cloud-init configuration generated"

# Clean up on exit (contains unencrypted private key)
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
        log_info "SSH key uploaded successfully"
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

    set +e
    DELETE_OUTPUT=$(hcloud firewall delete "$FIREWALL_NAME" 2>&1)
    DELETE_EXIT=$?
    set -e

    if [[ $DELETE_EXIT -eq 0 ]]; then
        log_info "Old firewall deleted"
    else
        log_error "Failed to delete firewall: $DELETE_OUTPUT"
        exit 1
    fi
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

# --- Store keys in SOPS ---
log_step "Storing WireGuard keys in SOPS..."

# Decrypt existing, update, re-encrypt via temp file (never write plaintext to real path)
DECRYPTED=$(sops -d "$SECRETS_FILE")

UPDATED=$(echo "$DECRYPTED" | grep -v "^wg_" || true)
UPDATED="${UPDATED}
wg_server_private_key: ${WG_SERVER_PRIVKEY}
wg_server_public_key: ${WG_SERVER_PUBKEY}
wg_routy_private_key: ${WG_ROUTY_PRIVKEY}
wg_routy_public_key: ${WG_ROUTY_PUBKEY}
wg_server_endpoint: ${SERVER_IP}"

# Write plaintext to temp .yaml in same directory (must match .sops.yaml path regex)
TMPFILE="${REPO_ROOT}/secrets/cloud/wg-keys-plaintext.yaml"
echo "$UPDATED" > "$TMPFILE"
trap 'rm -f "$CLOUD_INIT_FILE" "$TMPFILE"' EXIT
sops -e "$TMPFILE" > "$SECRETS_FILE"
rm -f "$TMPFILE"

log_info "Keys stored in $SECRETS_FILE"

# --- Store routy private key in routy's SOPS secrets ---
ROUTY_SECRETS="${REPO_ROOT}/secrets/routy/secrets.sops.yaml"
if [[ -f "$ROUTY_SECRETS" ]]; then
    log_step "Adding routy WireGuard private key to routy secrets..."
    ROUTY_DECRYPTED=$(sops -d "$ROUTY_SECRETS")

    if echo "$ROUTY_DECRYPTED" | grep -q "wireguard/egress-private-key"; then
        ROUTY_UPDATED=$(echo "$ROUTY_DECRYPTED" | sed "s|wireguard/egress-private-key:.*|wireguard/egress-private-key: ${WG_ROUTY_PRIVKEY}|")
    else
        ROUTY_UPDATED="${ROUTY_DECRYPTED}
wireguard/egress-private-key: ${WG_ROUTY_PRIVKEY}"
    fi

    ROUTY_TMP="${REPO_ROOT}/secrets/routy/wg-keys-plaintext.yaml"
    echo "$ROUTY_UPDATED" > "$ROUTY_TMP"
    trap 'rm -f "$CLOUD_INIT_FILE" "$TMPFILE" "$ROUTY_TMP"' EXIT
    sops -e "$ROUTY_TMP" > "$ROUTY_SECRETS"
    rm -f "$ROUTY_TMP"
    log_info "routy WireGuard key stored in $ROUTY_SECRETS"
else
    log_warn "routy secrets file not found at $ROUTY_SECRETS"
    log_warn "You will need to manually add the routy WireGuard private key"
fi

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
echo "  routy public key: $WG_ROUTY_PUBKEY"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait 1-2 minutes for cloud-init to complete"
echo "2. Verify VPS: ssh root@$SERVER_IP 'wg show'"
echo "3. Deploy routy config: just nix deploy routy"
echo "4. Verify tunnel: ssh routy.internal 'wg show wg-egress'"
echo "5. Test proxy: curl --socks5 10.1.0.1:1080 https://ifconfig.me"
echo ""
echo -e "${GREEN}To connect via SSH:${NC}"
echo "  ssh root@$SERVER_IP"
echo ""
echo -e "${GREEN}To check cloud-init progress:${NC}"
echo "  ssh root@$SERVER_IP 'tail -f /var/log/cloud-init-output.log'"
echo ""
echo -e "${YELLOW}If your home IP changes:${NC}"
echo "  FIREWALL_NAME=$FIREWALL_NAME ./update-home-ip.sh"
echo ""
echo -e "${RED}To destroy this server:${NC}"
echo "  ./deprovision-wg-exit.sh"
echo -e "${GREEN}================================${NC}"

# Clean up generated cloud-init file
rm -f "$CLOUD_INIT_FILE"
