#!/usr/bin/env bash
set -euo pipefail

# Updates the WireGuard server endpoint in routy's SOPS secrets.
# Run after provisioning a new VPS (provision-wg-exit.sh prints the IP).
#
# Usage: ./set-wg-endpoint.sh <VPS_IP>
#    or: ./set-wg-endpoint.sh          (auto-detects from hcloud)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROUTY_SECRETS="${REPO_ROOT}/secrets/routy/secrets.sops.yaml"
CLOUD_SECRETS="${REPO_ROOT}/secrets/cloud/secrets.sops.yaml"
SERVER_NAME="${SERVER_NAME:-wg-exit}"

if [[ ! -f "$ROUTY_SECRETS" ]]; then
    log_error "routy secrets not found: $ROUTY_SECRETS"
    exit 1
fi

# Get VPS IP
if [[ $# -ge 1 ]]; then
    VPS_IP="$1"
else
    if ! command -v hcloud &>/dev/null; then
        log_error "Usage: $0 <VPS_IP>"
        exit 1
    fi
    VPS_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
    if [[ -z "$VPS_IP" ]]; then
        log_error "Could not detect VPS IP. Pass it as argument: $0 <VPS_IP>"
        exit 1
    fi
    log_info "Detected VPS IP from hcloud: $VPS_IP"
fi

ENDPOINT="${VPS_IP}:51820"

# Helper: safely update a SOPS file (never truncates on failure)
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

# Update routy secrets
log_info "Setting endpoint to $ENDPOINT in routy secrets..."
ROUTY_DECRYPTED=$(sops -d "$ROUTY_SECRETS") || { log_error "Failed to decrypt $ROUTY_SECRETS"; exit 1; }
ROUTY_UPDATED=$(python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
if 'wireguard' not in data:
    print('ERROR: wireguard keys not found. Run generate-wg-keys.sh first.', file=sys.stderr)
    sys.exit(1)
data['wireguard']['egress-server-endpoint'] = '$ENDPOINT'
yaml.dump(data, sys.stdout, default_flow_style=False)
" <<< "$ROUTY_DECRYPTED")

sops_safe_update "$ROUTY_UPDATED" "$ROUTY_SECRETS" "${REPO_ROOT}/secrets/routy/wg-tmp.yaml"

# Also update cloud secrets
if [[ -f "$CLOUD_SECRETS" ]]; then
    CLOUD_DECRYPTED=$(sops -d "$CLOUD_SECRETS") || { log_error "Failed to decrypt $CLOUD_SECRETS"; exit 1; }
    CLOUD_UPDATED=$(echo "$CLOUD_DECRYPTED" | sed "s|^wg_server_endpoint:.*|wg_server_endpoint: ${VPS_IP}|")
    sops_safe_update "$CLOUD_UPDATED" "$CLOUD_SECRETS" "${REPO_ROOT}/secrets/cloud/wg-tmp.yaml"
fi

log_info "Endpoint updated to $ENDPOINT"
echo ""
echo -e "${YELLOW}Next:${NC} just nix deploy routy"
