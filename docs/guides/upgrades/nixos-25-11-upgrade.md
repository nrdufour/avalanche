# NixOS 25.11 Upgrade Summary

Date: 2025-12-01

## Overview
Successfully migrated Avalanche infrastructure from NixOS 24.x to 25.11. All 16 hosts now evaluate without errors or deprecation warnings.

## Changes Made

### Package Updates
- **garage**: `garage_2_1_0` → `garage_2` (cardinal/garage/default.nix:51)
- **kanidm**: `kanidm_1_7` → `kanidm_1_8` (mysecrets/kanidm/default.nix:4,16)
- **fonts**: `noto-fonts-emoji` → `noto-fonts-color-emoji` (laptop/fonts.nix:15)
- **fonts**: Removed `noto-fonts-extra` (merged into `noto-fonts`)
- **fonts**: `ubuntu_font_family` → `ubuntu-classic` (laptop/fonts.nix:16)

### Option Renames
| File | Old | New |
|------|-----|-----|
| hw-sdcard.nix:11 | `sdImage.imageName` | `image.fileName` |
| laptop/default.nix:16 | `services.logind.lidSwitchExternalPower` | `services.logind.settings.Login.HandleLidSwitchExternalPower` |

### Desktop Manager Refactoring
**File**: laptop/dm/gnome.nix:8-18
- Removed nested `services.xserver` wrapper
- Moved `desktopManager.gnome` to top-level `services.desktopManager.gnome`
- Moved `displayManager.gdm` to top-level `services.displayManager.gdm`

### Attribute Deprecations
| File | Old | New |
|------|-----|-----|
| overlays/default.nix:10 | `inherit (final) system;` | `system = final.stdenv.hostPlatform.system;` |
| personalities/development/vscode.nix:11 | `pkgs.system` | `pkgs.stdenv.hostPlatform.system` |
| modules/nixos/rknn.nix:7 | `pkgs.stdenv.isAarch64` | `pkgs.stdenv.hostPlatform.isAarch64` |

## Validation
```bash
nix flake check
# Result: ✓ All 16 NixOS configurations evaluate successfully
# No errors or deprecation warnings
```

## Files Modified
1. nixos/hosts/cardinal/garage/default.nix
2. nixos/hosts/mysecrets/kanidm/default.nix
3. nixos/profiles/hw-sdcard.nix
4. nixos/profiles/hw-orangepi5plus.nix (udev rules - no changes needed)
5. nixos/personalities/laptop/default.nix
6. nixos/personalities/laptop/dm/gnome.nix
7. nixos/personalities/laptop/fonts.nix
8. nixos/personalities/development/vscode.nix
9. nixos/overlays/default.nix
10. nixos/modules/nixos/rknn.nix

## Next Steps
- Deploy changes to hosts as needed
- Monitor for any runtime issues with upgraded packages (especially kanidm 1.8)
- Verify garage S3 storage functionality after upgrade

## Notes
- No changes needed to hardware profiles (hw-rpi4.nix, hw-rpi3.nix, hw-orangepi5plus.nix already compatible)
- No changes to flake inputs required
- All host stateVersions remain unchanged (NixOS best practice)
