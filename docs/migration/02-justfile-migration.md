# Justfile Migration

This document tracks the migration of the justfile from snowpea into avalanche.

## Migration Date

Completed: 2025-11-02

## What Was Copied

Copied as-is from snowpea with only the header comment updated:

### Main Justfile (`justfile`)
- Updated header: "SnowPea" → "Avalanche"
- Imports all sub-justfiles
- Default recipe lists all commands
- Lint and format commands

### Sub-Justfiles (`.justfiles/`)

**nix.just** - NixOS deployment and management:
- `nix-update` - Update flake.lock
- `nix-check` - Run flake check
- `nix-list-hosts` - List all NixOS configurations
- `nix-deploy <host>` - Deploy to a single host
- `nix-deploy-all` - Deploy to all hosts (with confirmation)

**sops.just** - Secrets management:
- `sops-update` - Update keys for all .sops.yaml files

**sd.just** - SD card image management:
- `sd-build <host>` - Build SD card image for a host
- `sd-flash <host>` - Build and flash SD card image with rpi-imager

## Usage Examples

```bash
# List all available commands
just

# Check the flake
just nix-check

# List all hosts
just nix-list-hosts

# Deploy to a specific host
just nix-deploy eagle

# Update SOPS keys
just sops-update

# Build SD card image
just sd-build raccoon00

# Flash SD card
just sd-flash raccoon00
```

## Network Assumptions

The deployment commands assume:
- Hosts are accessible via `<hostname>.internal` domain
- SSH access is configured
- Remote sudo is available

## Notes

All justfile recipes copied exactly from snowpea with no modifications
except for the main justfile header comment.

---

*Last updated: 2025-11-02*
