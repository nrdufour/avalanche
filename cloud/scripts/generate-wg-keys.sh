#!/usr/bin/env bash
set -euo pipefail

# Generates WireGuard keypairs for the VPN egress tunnel and stores them in SOPS.
# Run this ONCE before provisioning the VPS or deploying routy.
# Both provision-wg-exit.sh and routy's NixOS config read from these secrets.
#
# Stores:
#   secrets/cloud/secrets.sops.yaml  — both keypairs (server + routy)
#   secrets/routy/secrets.sops.yaml  — routy private key + server public key
#
# Safe to re-run: will detect existing keys and ask before overwriting.

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
for cmd in wg sops; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "$cmd not found"
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLOUD_SECRETS="${REPO_ROOT}/secrets/cloud/secrets.sops.yaml"
ROUTY_SECRETS="${REPO_ROOT}/secrets/routy/secrets.sops.yaml"

for f in "$CLOUD_SECRETS" "$ROUTY_SECRETS"; do
    if [[ ! -f "$f" ]]; then
        log_error "Secrets file not found: $f"
        exit 1
    fi
done

# Check for existing keys
EXISTING=$(sops -d "$CLOUD_SECRETS" 2>/dev/null | grep "wg_server_private_key:" | awk '{print $2}' || true)
if [[ -n "$EXISTING" && "$EXISTING" != "PLACEHOLDER" ]]; then
    log_warn "WireGuard keys already exist in SOPS."
    EXISTING_PUBKEY=$(echo "$EXISTING" | wg pubkey)
    log_info "  Server public key: $EXISTING_PUBKEY"
    read -rp "$(echo -e "${YELLOW}Overwrite with new keys? [y/N]:${NC} ")" -n 1 REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Keeping existing keys."
        exit 0
    fi
fi

# Generate keypairs
log_step "Generating WireGuard keypairs..."
WG_SERVER_PRIVKEY=$(wg genkey)
WG_SERVER_PUBKEY=$(echo "$WG_SERVER_PRIVKEY" | wg pubkey)
WG_ROUTY_PRIVKEY=$(wg genkey)
WG_ROUTY_PUBKEY=$(echo "$WG_ROUTY_PRIVKEY" | wg pubkey)

# Helper: safely update a SOPS file (never truncates on failure)
# Usage: sops_safe_update <plaintext_content> <sops_file> <tmp_file>
sops_safe_update() {
    local content="$1" target="$2" tmp_in="$3"
    local tmp_out="${target}.new"

    echo "$content" > "$tmp_in"
    if ! sops -e "$tmp_in" > "$tmp_out"; then
        rm -f "$tmp_in" "$tmp_out"
        log_error "Failed to encrypt $target"
        exit 1
    fi
    mv "$tmp_out" "$target"
    rm -f "$tmp_in"
}

# --- Store in cloud secrets ---
log_step "Storing keys in cloud secrets..."
CLOUD_DECRYPTED=$(sops -d "$CLOUD_SECRETS") || { log_error "Failed to decrypt $CLOUD_SECRETS"; exit 1; }
# Strip old wg_ keys
CLOUD_UPDATED=$(echo "$CLOUD_DECRYPTED" | grep -v "^wg_" || true)
CLOUD_UPDATED="${CLOUD_UPDATED}
wg_server_private_key: ${WG_SERVER_PRIVKEY}
wg_server_public_key: ${WG_SERVER_PUBKEY}
wg_routy_private_key: ${WG_ROUTY_PRIVKEY}
wg_routy_public_key: ${WG_ROUTY_PUBKEY}"

sops_safe_update "$CLOUD_UPDATED" "$CLOUD_SECRETS" "${REPO_ROOT}/secrets/cloud/wg-tmp.yaml"
log_info "Cloud secrets updated"

# --- Store in routy secrets ---
log_step "Storing keys in routy secrets..."
ROUTY_DECRYPTED=$(sops -d "$ROUTY_SECRETS") || { log_error "Failed to decrypt $ROUTY_SECRETS"; exit 1; }
# Remove existing wireguard block and re-add
ROUTY_UPDATED=$(python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
data.pop('wireguard', None)
data = {k: v for k, v in data.items() if not k.startswith('wireguard/')}
yaml.dump(data, sys.stdout, default_flow_style=False)
" <<< "$ROUTY_DECRYPTED")
ROUTY_UPDATED="${ROUTY_UPDATED}
wireguard:
    egress-private-key: ${WG_ROUTY_PRIVKEY}
    egress-server-pubkey: ${WG_SERVER_PUBKEY}"

sops_safe_update "$ROUTY_UPDATED" "$ROUTY_SECRETS" "${REPO_ROOT}/secrets/routy/wg-tmp.yaml"
log_info "routy secrets updated"

# --- Summary ---
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}WireGuard Keys Generated${NC}"
echo -e "${GREEN}================================${NC}"
echo "Server public key:  $WG_SERVER_PUBKEY"
echo "routy public key:   $WG_ROUTY_PUBKEY"
echo ""
echo "Keys stored in:"
echo "  $CLOUD_SECRETS"
echo "  $ROUTY_SECRETS"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Provision VPS:     ./provision-wg-exit.sh"
echo "2. Update endpoint:   ./set-wg-endpoint.sh <VPS_IP>"
echo "3. Deploy routy:      just nix deploy routy"
echo -e "${GREEN}================================${NC}"
