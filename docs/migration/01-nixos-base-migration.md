# NixOS Base Migration

This document tracks the migration of NixOS configurations from snowpea (and later snowy) into avalanche.

## Migration Date

Started: 2025-11-02

## Step 1: Copy Snowpea Base Structure ✅

**Date:** 2025-11-02

### What Was Copied (As-Is from snowpea)

All files copied exactly as-is, no modifications:

#### Profiles (`nixos/profiles/`)
- `global.nix` - Main global profile that imports the global/ subdirectory
- `global/` - Subdirectory containing:
  - `default.nix` - Imports all global configs
  - `nix.nix` - Nix daemon settings, flake registry, cachix, garbage collection
  - `oci-containers.nix` - Podman/Docker configuration with registry mirrors
  - `sops.nix` - Global SOPS secrets configuration (currently empty)
  - `system.nix` - System-level settings (stateVersion, etc)
  - `users.nix` - User configuration for ndufour with SSH keys

#### Hardware Profiles (`nixos/profiles/hw-*.nix`)
- `hw-acer-minipc.nix` - Acer mini PC configuration
- `hw-orangepi5plus.nix` - Orange Pi 5 Plus configuration
- `hw-rpi3.nix` - Raspberry Pi 3 configuration
- `hw-rpi4.nix` - Raspberry Pi 4 configuration
- `hw-sdcard.nix` - SD card-specific configuration

#### Role Profiles (`nixos/profiles/role-*.nix`)
- `role-server.nix` - Common server role configuration
- `role-k3s-controller.nix` - K3s controller node role
- `role-k3s-worker.nix` - K3s worker node role

#### Modules (`nixos/modules/nixos/`)
- `default.nix` - Module aggregation
- `security/` - Security-related modules
- `services/` - Service modules
- `system/` - System modules

#### Supporting Files
- `nixos/lib/default.nix` - Custom helper functions (currently empty placeholder)
- `nixos/overlays/default.nix` - NUR and unstable packages overlays

### Flake Configuration

Created `flake.nix` with:
- All inputs from both snowpea and snowy combined:
  - nixpkgs (stable 25.05)
  - nixpkgs-unstable
  - nixos-hardware
  - NUR
  - sops-nix
  - nix-vscode-extensions (for workstation support)

- `mkNixosConfig` helper function (copied from snowpea pattern):
  - Supports hardware modules
  - Supports profile modules
  - Supports custom system architecture
  - Supports state version override
  - Applies overlays automatically
  - Includes global profile and modules by default

- Host configurations section (currently placeholder for migration)

### Key Details Preserved

From `global/users.nix`:
- User: ndufour
- Shell: fish
- SSH key: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAjRgUY8iJkzNdbWvMv65NZmcWx3DSUCnv/FMw63nxl

From `global.nix`:
- Timezone: America/New_York (NOT Toronto!)
- Boot temp cleanup: enabled
- DHCP: enabled by default

From `global/nix.nix`:
- Cachix substituters:
  - nrdufour.cachix.org
  - nix-community.cachix.org
  - numtide.cachix.org
- GC: daily, delete >7 days old
- Trusted users: root, @wheel

## Step 2: Copy Individual Host Configurations ✅

**Date:** 2025-11-02

### Hosts Copied from snowpea

All host configurations copied as-is from `/home/ndufour/Documents/code/projects/ops/snowpea/nixos/hosts/`:

**Infrastructure Services:**
- `eagle` - Raspberry Pi 4 (Forgejo)
- `mysecrets` - Raspberry Pi 4 (step-ca, Vaultwarden)
- `possum` - Raspberry Pi 4 (Garage S3, backups)

**K3s Worker Nodes (Raspberry Pi 4):**
- `raccoon00` through `raccoon05` (6 nodes)

**K3s Controller Nodes (Orange Pi 5 Plus):**
- `opi01`, `opi02`, `opi03` (3 nodes)

**x86 Servers:**
- `beacon` - Acer mini PC
- `routy` - x86_64 server (stateVersion 25.05)
- `cardinal` - x86_64 server (stateVersion 25.05)

**Decommissioned/Archived:**
- `sparrow01` - Raspberry Pi 3 (copied but not active in flake)

### Flake Configuration Updated

All active hosts (14 total) added to `flake.nix` with exact configurations from snowpea:
- 3 infrastructure services (RPi 4)
- 6 K3s workers (RPi 4)
- 3 K3s controllers (Orange Pi 5+)
- 2 x86 servers with stateVersion 25.05
- 1 x86 Acer mini PC

### Next Steps

- Verify flake builds successfully (`nix flake check`)
- Test building individual hosts
- Proceed to snowy integration

## Step 3: Integrate Snowy (Pending)

Next steps:
- Create `role-workstation.nix` profile for laptop
- Copy calypso host configuration
- Add workstation-specific modules
- Handle nixos-hardware integration for ASUS ROG

## Notes

- All snowpea content was copied AS-IS with no modifications
- Original timezone (America/New_York) preserved
- Original user configuration preserved
- Cachix configuration preserved
- OCI containers backend defaults to Podman

---

*Last updated: 2025-11-02*
