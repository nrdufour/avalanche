#!/usr/bin/env bash
set -euo pipefail

# Configuration
SERVER_NAME="${SERVER_NAME:-wg-exit}"
FIREWALL_NAME="${FIREWALL_NAME:-${SERVER_NAME}-fw}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Check if hcloud is configured
if ! hcloud context list &>/dev/null; then
    log_error "hcloud is not configured. Run 'hcloud context create' first."
    exit 1
fi

# Check if server exists
log_info "Checking if server '$SERVER_NAME' exists..."
if ! hcloud server describe "$SERVER_NAME" &>/dev/null; then
    log_error "Server '$SERVER_NAME' not found!"
    log_info "Available servers:"
    hcloud server list
    exit 1
fi

# Get server details
SERVER_IP=$(hcloud server ip "$SERVER_NAME")
SERVER_TYPE=$(hcloud server describe "$SERVER_NAME" -o json | grep -oP '"server_type":\s*{\s*"name":\s*"\K[^"]+' || echo "unknown")
SERVER_LOCATION=$(hcloud server describe "$SERVER_NAME" -o json | grep -oP '"location":\s*{\s*"name":\s*"\K[^"]+' || echo "unknown")

echo ""
echo -e "${YELLOW}================================${NC}"
echo -e "${YELLOW}Resources to be deleted${NC}"
echo -e "${YELLOW}================================${NC}"
echo "Server:"
echo "  Name:     $SERVER_NAME"
echo "  IP:       $SERVER_IP"
echo "  Type:     $SERVER_TYPE"
echo "  Location: $SERVER_LOCATION"
echo ""

# Check if firewall exists
FIREWALL_EXISTS=false
if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
    FIREWALL_EXISTS=true
    echo "Firewall:"
    echo "  Name:     $FIREWALL_NAME"
    echo "  Status:   Will be deleted"
fi

echo -e "${YELLOW}================================${NC}"
echo ""

# Confirmation prompt
read -rp "$(echo -e "${RED}Are you sure you want to delete these resources? [y/N]:${NC} ")" -n 1 REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted. Nothing deleted."
    exit 0
fi

# Delete server
log_info "Deleting server '$SERVER_NAME'..."
hcloud server delete "$SERVER_NAME"

# Delete firewall if it exists and is not attached to other servers
if [[ "$FIREWALL_EXISTS" = true ]]; then
    log_info "Checking if firewall is attached to other servers..."
    ATTACHED_COUNT=$(hcloud firewall describe "$FIREWALL_NAME" -o json | grep -oP '"applied_to":\s*\[\K[^\]]' | wc -l)

    if [[ "$ATTACHED_COUNT" -eq 0 ]]; then
        log_info "Deleting firewall '$FIREWALL_NAME'..."
        hcloud firewall delete "$FIREWALL_NAME"
    else
        log_warn "Firewall '$FIREWALL_NAME' is still attached to other servers. Not deleting."
    fi
fi

log_info "Resources deleted successfully!"
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${YELLOW}Notes:${NC}"
echo "- WireGuard keys are still in SOPS (reusable if you reprovision)"
echo "- routy's WireGuard interface will fail to connect until a new VPS is provisioned"
echo "- To reprovision: ./provision-wg-exit.sh (will reuse existing keys)"
echo -e "${GREEN}================================${NC}"
