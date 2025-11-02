# Snowy Workstation Migration

This document tracks the migration of the snowy laptop configuration (calypso) into avalanche.

## Migration Date

Completed: 2025-11-02

## What Was Migrated

### Personalities Structure (from snowy)

Copied complete modular personality system:

**nixos/personalities/** - Modular configuration system
- `base/` - Core system configuration (7 modules)
  - bootloader.nix, fish.nix, locales.nix, network.nix
  - nixos.nix, users.nix, zfs.nix
- `laptop/` - Laptop-specific features (10 modules)
  - asusd.nix (ASUS ROG hardware control)
  - bluetooth.nix, browsing.nix, custom_kernel.nix
  - dm/ (display manager - GNOME + NVIDIA)
  - fonts.nix, gaming.nix, printing.nix, sound.nix, video.nix
- `development/` - Development tools (8 modules)
  - ai.nix, cloud.nix, container.nix, docker.nix
  - libvirtd.nix, podman.nix, privateca/, vscode.nix, virtualbox.nix
- `ham/` - Amateur radio tools
- `chat/` - Communication tools
- `backups/` - Backup configuration
- `knowledge/` - Knowledge management tools

### New Role Profile

**nixos/profiles/role-workstation.nix**
- Imports core personalities: base, laptop, development
- Enables NetworkManager for workstations
- User-specific personalities imported by host configs

### Host Configuration

**nixos/hosts/calypso/**
- ASUS ROG Strix G513IM laptop configuration
- Imports user-specific personalities (ham, chat, backups, knowledge)
- Core personalities provided by role-workstation.nix
- SOPS secrets for backup credentials
- stateVersion: 24.05

### Hardware Support

- nixos-hardware ASUS ROG Strix module integration
- Hardware-configuration.nix from snowy
- NVIDIA GPU support via personalities/laptop/dm/nvidia.nix

### Secrets

- `secrets/calypso/secrets.sops.yaml` - Backup credentials
- Updated `.sops.yaml`:
  - Added workstation-calypso Age key
  - Added creation rule for calypso secrets

### Flake Integration

Added calypso to flake.nix:
```nix
calypso = mkNixosConfig {
  hostname = "calypso";
  system = "x86_64-linux";
  stateVersion = "24.05";
  hardwareModules = [
    inputs.nixos-hardware.nixosModules.asus-rog-strix-g513im
  ];
  profileModules = [
    ./nixos/profiles/role-workstation.nix
  ];
};
```

## Modifications Made

### Conflict Resolutions

**User Configuration Conflict:**
- Issue: Both global/users.nix and personalities/base/users.nix defined user ndufour
- Solution: Added lib.mkDefault to personalities/base/users.nix
- Result: global/users.nix takes precedence (has SSH keys + more groups)

**Nixpkgs Config Conflicts:**
- Issue: Personalities tried to set nixpkgs.config but pkgs created in flake
- Solutions:
  - Commented out `allowUnfree` in personalities/base/nixos.nix
  - Commented out chromium config in personalities/laptop/browsing.nix
  - Added `chromium.enableWideVine = true` to flake's pkgs config
- Result: All nixpkgs.config handled in flake, no module conflicts

**Nix GC Configuration Conflict:**
- Issue: personalities/base/nixos.nix (weekly) vs global/nix.nix (daily)
- Solution: Added lib.mkDefault to personalities/base/nixos.nix GC settings
- Result: global/nix.nix takes precedence (daily GC)

### Design Decisions

**Modular Personalities:**
- Kept snowy's personality structure for maximum modularity
- role-workstation.nix imports only core personalities
- User-specific personalities imported per host

**Priority System:**
- Personalities use lib.mkDefault for settings
- Global profiles override personality defaults
- Allows per-host customization while maintaining consistency

## Flake Validation

**Result:** ✅ All 15 hosts pass `nix flake check`

- 14 servers from snowpea ✓
- 1 workstation from snowy (calypso) ✓

## Repository Status

```
avalanche/
├── nixos/
│   ├── hosts/              ✅ 15 hosts (14 servers + 1 workstation)
│   ├── profiles/           ✅ Server + workstation roles
│   ├── personalities/      ✅ Modular workstation features (from snowy)
│   ├── modules/            ✅ Custom modules
│   └── pkgs/               ✅ Custom packages
├── kubernetes/             ✅ Complete GitOps manifests (from home-ops)
├── secrets/                ✅ All secrets (snowpea + snowy)
├── .sops.yaml              ✅ Unified SOPS config
└── flake.nix               ✅ 15 NixOS configurations
```

## Compatibility Notes

**Workstation vs Server Differences:**
- Workstations use NetworkManager (servers use systemd-networkd)
- Workstations have desktop environment, audio, fonts
- Workstations use personalities (servers use profiles)
- Both share global profile for consistency

**Future Workstations:**
- Use role-workstation.nix profile
- Add personalities as needed per host
- Follow calypso as reference example

---

*Last updated: 2025-11-02*
