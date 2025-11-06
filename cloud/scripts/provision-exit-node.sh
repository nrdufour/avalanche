#!/usr/bin/env bash
set -euo pipefail

# Configuration
SERVER_NAME="${SERVER_NAME:-tailscale-exit}"
FIREWALL_NAME="${FIREWALL_NAME:-${SERVER_NAME}-fw}"
SERVER_TYPE="${SERVER_TYPE:-cpx11}"  # €3.85/month (replaces deprecated cx22)
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

# Check if hcloud is configured
if ! hcloud context list &>/dev/null; then
    log_error "hcloud is not configured. Run 'hcloud context create' first."
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_INIT_TEMPLATE="${SCRIPT_DIR}/cloud-init.yaml.template"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init.yaml"
SECRETS_FILE="${REPO_ROOT}/secrets/cloud/secrets.sops.yaml"

# Check if cloud-init template exists
if [[ ! -f "$CLOUD_INIT_TEMPLATE" ]]; then
    log_error "cloud-init.yaml.template not found at $CLOUD_INIT_TEMPLATE"
    exit 1
fi

# Check if SOPS secrets file exists
if [[ ! -f "$SECRETS_FILE" ]]; then
    log_error "Cloud secrets file not found at $SECRETS_FILE"
    log_info "Expected: $SECRETS_FILE"
    exit 1
fi

# Generate cloud-init file from template with SOPS secrets
log_step "Generating cloud-init configuration from SOPS secrets..."

# Decrypt and extract Tailscale auth key
TAILSCALE_AUTH_KEY=$(sops -d "$SECRETS_FILE" | grep "tailscale_auth_key:" | awk '{print $2}')

if [[ -z "$TAILSCALE_AUTH_KEY" ]] || [[ "$TAILSCALE_AUTH_KEY" == "YOUR_TAILSCALE_AUTH_KEY_HERE" ]]; then
    log_error "Tailscale auth key not set in $SECRETS_FILE"
    log_info "Please edit the secrets file and add your Tailscale auth key:"
    log_info "  sops $SECRETS_FILE"
    log_info ""
    log_info "Get an auth key from: https://login.tailscale.com/admin/settings/keys"
    log_info "Recommended: Create a reusable key that doesn't expire"
    exit 1
fi

# Generate cloud-init.yaml from template
sed "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" "$CLOUD_INIT_TEMPLATE" > "$CLOUD_INIT_FILE"
log_info "Cloud-init configuration generated successfully"

# Set up trap to clean up cloud-init file on exit
trap 'rm -f "$CLOUD_INIT_FILE"' EXIT

log_info "Checking if server '$SERVER_NAME' already exists..."
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    log_error "Server '$SERVER_NAME' already exists!"
    log_info "Either delete it first with: hcloud server delete $SERVER_NAME"
    log_info "Or use the deprovision script: ./deprovision-exit-node.sh"
    exit 1
fi

# Get home IP address
log_step "Detecting home IP address..."
HOME_IP=$(curl -s https://api.ipify.org)
if [[ -z "$HOME_IP" ]]; then
    log_error "Failed to detect home IP address"
    read -p "Please enter your home IP address: " HOME_IP
fi
log_info "Home IP: $HOME_IP"

# Confirm IP
read -p "$(echo -e ${YELLOW}Is this your correct home IP? [Y/n]:${NC} )" -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    read -p "Enter your home IP address: " HOME_IP
fi

# Check/create SSH key
log_step "Checking SSH key..."
SSH_KEY_TO_USE=""

if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
    # Key with our desired name exists
    SSH_KEY_TO_USE="$SSH_KEY_NAME"
    log_info "Using existing SSH key: $SSH_KEY_NAME"
else
    log_warn "SSH key '$SSH_KEY_NAME' not found in Hetzner."

    # Determine which local SSH key to use
    LOCAL_SSH_KEY=""
    if [[ -f ~/.ssh/id_ed25519.pub ]]; then
        LOCAL_SSH_KEY=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub ]]; then
        LOCAL_SSH_KEY=~/.ssh/id_rsa.pub
    else
        log_error "No SSH key found at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub"
        log_info "Please generate one with: ssh-keygen -t ed25519"
        exit 1
    fi

    # Try to create the key
    log_info "Uploading local SSH key ($LOCAL_SSH_KEY)..."
    if hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$LOCAL_SSH_KEY" 2>&1; then
        SSH_KEY_TO_USE="$SSH_KEY_NAME"
        log_info "SSH key uploaded successfully"
    else
        # Key might already exist with different name - find it by fingerprint
        log_warn "SSH key content already exists in Hetzner with a different name"

        # Get local key fingerprint in MD5 format (Hetzner uses MD5)
        LOCAL_FINGERPRINT=$(ssh-keygen -E md5 -lf "$LOCAL_SSH_KEY" | awk '{print $2}' | sed 's/MD5://')

        # Find matching key in Hetzner
        log_info "Searching for existing key with matching fingerprint..."
        EXISTING_KEY=$(hcloud ssh-key list -o columns=name,fingerprint | tail -n +2 | grep "$LOCAL_FINGERPRINT" | awk '{print $1}')

        if [[ -n "$EXISTING_KEY" ]]; then
            SSH_KEY_TO_USE="$EXISTING_KEY"
            log_info "Found existing SSH key: $EXISTING_KEY"
            log_info "Will use this key for the server"
        else
            log_error "Could not find existing SSH key. Please check your Hetzner SSH keys manually."
            log_info "Run: hcloud ssh-key list"
            exit 1
        fi
    fi
fi

# Create or update firewall
log_step "Setting up firewall..."
if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
    log_warn "Firewall '$FIREWALL_NAME' already exists. Deleting and recreating..."

    # Check if it's attached to any servers (check if applied_to array is not empty)
    APPLIED_TO=$(hcloud firewall describe "$FIREWALL_NAME" -o json 2>/dev/null | grep '"applied_to"' | grep -v '\[\]' || true)

    if [[ -n "$APPLIED_TO" ]]; then
        log_error "Firewall '$FIREWALL_NAME' is still attached to servers."
        log_info "Please run './deprovision-exit-node.sh' first to clean up."
        exit 1
    fi

    # Delete the old firewall
    log_info "Deleting firewall '$FIREWALL_NAME'..."
    set +e  # Temporarily disable exit on error
    DELETE_OUTPUT=$(hcloud firewall delete "$FIREWALL_NAME" 2>&1)
    DELETE_EXIT=$?
    set -e  # Re-enable exit on error

    if [[ $DELETE_EXIT -eq 0 ]]; then
        log_info "Old firewall deleted successfully"
    else
        log_error "Failed to delete firewall '$FIREWALL_NAME'"
        log_error "Error: $DELETE_OUTPUT"
        log_info "Please delete it manually with:"
        log_info "  hcloud firewall delete $FIREWALL_NAME"
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
    "protocol": "icmp",
    "description": "Allow ICMP (ping)"
  }
]
EOF
)

# Create server
log_step "Creating server '$SERVER_NAME'..."
log_info "  Type: $SERVER_TYPE"
log_info "  Location: $LOCATION"
log_info "  Image: $IMAGE"
log_info "  SSH Key: $SSH_KEY_TO_USE"
log_info "  Firewall: $FIREWALL_NAME (SSH restricted to $HOME_IP)"

hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --location "$LOCATION" \
    --image "$IMAGE" \
    --ssh-key "$SSH_KEY_TO_USE" \
    --firewall "$FIREWALL_NAME" \
    --user-data-from-file "$CLOUD_INIT_FILE"

# Wait for server to be running
log_info "Waiting for server to be running..."
sleep 5

# Get server info
SERVER_IP=$(hcloud server ip "$SERVER_NAME")
SERVER_ID=$(hcloud server describe "$SERVER_NAME" -o json | grep -oP '"id":\s*\K\d+' | head -1)

log_info "Server created successfully!"
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Server Details${NC}"
echo -e "${GREEN}================================${NC}"
echo "Name:       $SERVER_NAME"
echo "ID:         $SERVER_ID"
echo "IP Address: $SERVER_IP"
echo "Firewall:   $FIREWALL_NAME"
echo "SSH Access: ${HOME_IP}/32 only"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait 1-2 minutes for cloud-init to complete Tailscale setup"
echo "2. Check server status: ssh root@$SERVER_IP 'tailscale status'"
echo "3. Approve exit node in Tailscale admin: https://login.tailscale.com/admin/machines"
echo "4. Look for device named '$SERVER_NAME' and approve its exit node capability"
echo ""
echo -e "${GREEN}To connect via SSH:${NC}"
echo "  ssh root@$SERVER_IP"
echo ""
echo -e "${GREEN}To check cloud-init progress:${NC}"
echo "  ssh root@$SERVER_IP 'tail -f /var/log/cloud-init-output.log'"
echo ""
echo -e "${YELLOW}If your home IP changes:${NC}"
echo "  ./update-home-ip.sh"
echo ""
echo -e "${RED}To destroy this server:${NC}"
echo "  ./deprovision-exit-node.sh"
echo -e "${GREEN}================================${NC}"

# Clean up generated cloud-init file (contains unencrypted secrets)
log_info "Cleaning up generated cloud-init file..."
rm -f "$CLOUD_INIT_FILE"
