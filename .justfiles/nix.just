# Nix-related commands

# Update the inputs in the flake.lock file
nix-update:
    nix flake update

# Check the flake is ok
nix-check:
    nix flake check

# List the NixOS hosts in the flake
nix-list-hosts:
    @nix flake show --json 2>/dev/null | jq -r '.nixosConfigurations | keys.[]'

# Deploy the configuration of a given host (remote)
nix-deploy host:
    nixos-rebuild switch -j auto --use-remote-sudo --build-host {{host}}.internal --target-host {{host}}.internal --flake ".#{{host}}" --fast

# Switch to a configuration locally (for current machine only)
nix-switch:
    sudo nixos-rebuild switch --flake ".#"

# Deploy flake to all nodes (with confirmation)
nix-deploy-all:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check prerequisites
    if ! command -v nix &> /dev/null; then
        echo "Error: nix not found"
        exit 1
    fi
    if ! command -v nixos-rebuild &> /dev/null; then
        echo "Error: nixos-rebuild not found"
        exit 1
    fi

    echo "This will deploy the local flake to all whitelisted hosts."
    read -p "Do you want to continue applying this configuration? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    # Get all hosts and deploy to each
    HOSTS=$(nix flake show --json 2>/dev/null | jq -r '.nixosConfigurations | keys.[]')
    for HOST in $HOSTS; do
        echo "Deploying to $HOST..."
        nixos-rebuild switch -j auto --use-remote-sudo --build-host ${HOST}.internal --target-host ${HOST}.internal --flake ".#${HOST}" --fast
    done

# Disable automatic NixOS upgrades on all hosts (stops timer until reboot/manual start)
nix-disable-autoupgrade:
    #!/usr/bin/env bash
    set -euo pipefail

    HOSTS=$(nix flake show --json 2>/dev/null | jq -r '.nixosConfigurations | keys.[]')
    FAILED_HOSTS=()

    echo "Disabling auto-upgrade on all hosts..."
    for HOST in $HOSTS; do
        echo -n "  $HOST... "
        if ssh -o ConnectTimeout=5 ${HOST}.internal "sudo systemctl stop nixos-upgrade.timer" >/dev/null 2>&1; then
            echo "✓"
        else
            echo "✗ (failed or unreachable)"
            FAILED_HOSTS+=("$HOST")
        fi
    done

    if [ ${#FAILED_HOSTS[@]} -gt 0 ]; then
        echo ""
        echo "Failed hosts: ${FAILED_HOSTS[*]}"
        exit 1
    fi

# Enable automatic NixOS upgrades on all hosts (starts timer immediately)
nix-enable-autoupgrade:
    #!/usr/bin/env bash
    set -euo pipefail

    HOSTS=$(nix flake show --json 2>/dev/null | jq -r '.nixosConfigurations | keys.[]')
    FAILED_HOSTS=()

    echo "Enabling auto-upgrade on all hosts..."
    for HOST in $HOSTS; do
        echo -n "  $HOST... "
        if ssh -o ConnectTimeout=5 ${HOST}.internal "sudo systemctl start nixos-upgrade.timer" >/dev/null 2>&1; then
            echo "✓"
        else
            echo "✗ (failed or unreachable)"
            FAILED_HOSTS+=("$HOST")
        fi
    done

    if [ ${#FAILED_HOSTS[@]} -gt 0 ]; then
        echo ""
        echo "Failed hosts: ${FAILED_HOSTS[*]}"
        exit 1
    fi
