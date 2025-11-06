#!/usr/bin/env bash
set -euo pipefail

# Configuration
FIREWALL_NAME="${FIREWALL_NAME:-tailscale-exit-fw}"

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

# Check if firewall exists
log_step "Checking firewall '$FIREWALL_NAME'..."
if ! hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
    log_error "Firewall '$FIREWALL_NAME' not found!"
    log_info "Available firewalls:"
    hcloud firewall list
    exit 1
fi

# Get current SSH rule
log_step "Getting current SSH rule..."
CURRENT_RULE=$(hcloud firewall describe "$FIREWALL_NAME" -o json | grep -A5 '"port": "22"' | grep -oP '"source_ips":\s*\[\s*"\K[^"]+' | head -1)
CURRENT_IP="${CURRENT_RULE%/*}"

if [[ -z "$CURRENT_IP" ]]; then
    log_warn "Could not find current SSH rule in firewall"
    CURRENT_IP="unknown"
fi

log_info "Current SSH access: $CURRENT_IP"

# Get new home IP address
log_step "Detecting current public IP..."
NEW_IP=$(curl -s https://api.ipify.org)
if [[ -z "$NEW_IP" ]]; then
    log_error "Failed to detect public IP address"
    read -p "Please enter your new home IP address: " NEW_IP
fi

log_info "Detected IP: $NEW_IP"

# Check if IPs are the same
if [[ "$CURRENT_IP" == "$NEW_IP" ]]; then
    log_info "IP address hasn't changed. No update needed."
    exit 0
fi

# Confirm update
echo ""
echo -e "${YELLOW}IP Address Change${NC}"
echo "  Current: $CURRENT_IP"
echo "  New:     $NEW_IP"
echo ""
read -p "$(echo -e ${YELLOW}Update firewall rule with new IP? [Y/n]:${NC} )" -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    log_info "Aborted. Firewall not updated."
    exit 0
fi

# Update firewall rule
log_step "Updating firewall rule..."

# First, try to remove any existing SSH rules (might have different IPs)
log_info "Removing old SSH rules..."
hcloud firewall delete-rule "$FIREWALL_NAME" --direction in --protocol tcp --port 22 2>/dev/null || log_warn "No existing SSH rule to remove"

# Add new rule with new IP
log_info "Adding new SSH rule for ${NEW_IP}/32..."
hcloud firewall add-rule "$FIREWALL_NAME" \
    --direction in \
    --source-ips "${NEW_IP}/32" \
    --protocol tcp \
    --port 22 \
    --description "SSH from home"

log_info "Firewall updated successfully!"
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}SSH Access Updated${NC}"
echo -e "${GREEN}================================${NC}"
echo "Firewall:  $FIREWALL_NAME"
echo "Old IP:    $CURRENT_IP"
echo "New IP:    $NEW_IP"
echo ""
echo -e "${GREEN}You can now SSH to the server from $NEW_IP${NC}"
echo -e "${GREEN}================================${NC}"
