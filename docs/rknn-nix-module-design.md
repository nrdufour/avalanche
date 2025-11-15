# RKNN Nix Module - Architecture & Design Document

## Overview

This document outlines the design decisions and architecture for packaging and integrating RKNN (Rockchip Neural Network) toolkit components into the Avalanche NixOS infrastructure.

## Context

- **Avalanche structure**: Uses `nixos/modules/nixos/` for NixOS modules (not personalities)
- **Module pattern**: See `minio.nix` for reference (service-based modules with enable flags)
- **Package structure**: Custom packages in `nixos/pkgs/` (e.g., mali-firmware)
- **Overlays**: Applied globally through `nixos/overlays/default.nix`
- **Hardware**: Orange Pi 5 Plus (RK3588, aarch64-linux only)

## Design Decisions

### 1. Packaging Strategy

**Decision**: Use **pre-built binaries from EZRKNN-Toolkit2** with Nix packaging

**Rationale**:
- RKNN components are pre-compiled Rockchip binaries (not open-source buildable)
- Building from source would require Rockchip's proprietary toolchain
- EZRKNN-Toolkit2 provides organized, ready-to-use binaries
- Simpler, reproducible approach

**Alternative considered**: Packaging official Rockchip RKNN-Toolkit2 - more complex, same outcome

### 2. Package Organization

Create separate, focused packages:

```
nixos/pkgs/rknn/
├── default.nix (meta-package, imports all)
├── runtime.nix (librknnrt.so, headers, dev files)
├── toolkit-lite.nix (Python rknnlite library)
└── tools.nix (benchmarks, utilities)
```

**Rationale**:
- Clean separation of concerns
- Allows selective imports
- Easier to maintain and update individual components
- Runtime is the core; toolkit-lite adds Python support; tools are optional

### 3. NixOS Module Strategy

Create `nixos/modules/nixos/rknn.nix` with two main sections:

#### Section A: Package Configuration
- Expose package options
- Allow version pinning
- Control which components are installed

#### Section B: System Configuration
- Set up environment variables (library paths, include paths)
- Configure device access (`/dev/rknpu*`)
- Setup kernel driver module loading (if needed)
- Create symlinks for library discovery

**Module options** (under `mySystem.rknn.*`):
```
mySystem.rknn = {
  enable = true/false
  enableRuntime = true (librknnrt)
  enableToolkitLite = true (Python bindings)
  enableTools = false (benchmarks - optional)
  runtimePackage = ... (pinned version)
}
```

### 4. Device Access & Permissions

**Challenge**: RKNN requires access to `/dev/rknpu*` devices

**Solution approach**:
1. **Load kernel driver module** (`rknpu` or `rknpu2`)
   - May already be in Orange Pi kernel
   - If not, need to either:
     - Build vendor kernel module
     - Or use pre-built module binary
2. **Set device permissions**
   - Create udev rules for `/dev/rknpu*`
   - Make accessible to non-root users (or just root)
3. **Verify hardware availability**
   - Check `/proc/device-tree/compatible` for `rk3588`
   - Only enable module on RK3588 hardware

### 5. Python Bindings Integration

**rknnlite Python module** needs to find `librknnrt.so` at runtime

**Solution**:
- Install Python package via overlay or custom derivation
- Set `LD_LIBRARY_PATH` in environment
- Or use `rpath` to embed library paths
- Test with: `python3 -c "from rknnlite.api import RKNNLite"`

### 6. Integration with Orange Pi Profile

**Current state**: `role-k3s-worker.nix` is minimal

**Two options**:

**Option A** (Recommended): Add to `role-k3s-worker.nix`
```nix
{
  mySystem.rknn.enable = true;
}
```
- All K3s workers on Orange Pi get NPU support
- Simple, discoverable
- Aligns with role-based architecture

**Option B**: Create `role-k3s-worker-npu.nix`
- For selective rollout
- More complex
- Can do later if needed

**Current choice**: Option A (keep simple, can always make optional later)

### 7. Deployment Flow

```
flake.nix (opi01-03 configs)
  ↓
mkNixosConfig with hardwareModules (hw-orangepi5plus.nix)
  ↓
profileModules includes role-k3s-worker.nix
  ↓
baseModules includes nixos/modules/nixos/ (our rknn.nix)
  ↓
Environment has RKNN packages + device access configured
```

## File Structure

```
nixos/
├── pkgs/rknn/
│   ├── default.nix
│   ├── runtime.nix
│   ├── toolkit-lite.nix
│   └── tools.nix
├── modules/nixos/
│   └── rknn.nix (new module)
├── overlays/
│   └── rknn-packages.nix (new overlay - optional)
└── profiles/
    └── role-k3s-worker.nix (modified - add mySystem.rknn config)
```

## Implementation Phases

### Phase 1a: Create Packages
1. `rknn/runtime.nix` - librknnrt.so, headers, dev files
2. `rknn/toolkit-lite.nix` - Python bindings
3. `rknn/tools.nix` - Benchmarks (optional)
4. `rknn/default.nix` - Meta-package
5. Register in overlays (for easy access via `pkgs.rknn-*`)

### Phase 1b: Create NixOS Module
1. `modules/nixos/rknn.nix`
   - Options for enable, package selection
   - Environment setup (LD_LIBRARY_PATH, etc.)
   - Device permission configuration
   - Kernel driver module loading
2. Update `modules/nixos/default.nix` to import rknn module

### Phase 1c: Integration
1. Update `role-k3s-worker.nix` to enable RKNN
2. Or update flake.nix opi configs directly (if simpler)

## Key Technical Challenges

1. **Python package distribution**
   - rknnlite comes as `.whl` file in EZRKNN-Toolkit2
   - May need custom buildPythonPackage wrapper
   - Library path discovery at runtime

2. **Device driver availability**
   - Kernel module may need to be built or provided
   - Check if Orange Pi 5 Plus kernel includes rknpu driver
   - May need vendor kernel module as binary

3. **Library path management**
   - Multiple options: LD_LIBRARY_PATH, rpath, nix wrapping
   - Test during Phase 2 hardware testing

4. **Conditional compilation for aarch64 only**
   - Use `lib.mkIf (config.nixpkgs.system == "aarch64-linux")` or similar
   - Or hardware profile checks

## Success Criteria (Phase 1)

- [ ] All RKNN packages build without errors
- [ ] Packages are reproducible (same hash each time)
- [ ] Module is importable and doesn't break existing configs
- [ ] `nix flake check` passes
- [ ] Build output includes librknnrt.so, headers, Python module

## Next Steps

1. Investigate EZRKNN-Toolkit2 binary structure (fetch URLs, SHA hashes)
2. Check Orange Pi 5 Plus kernel for rknpu driver module
3. Create `nixos/pkgs/rknn/runtime.nix`
4. Create `nixos/pkgs/rknn/toolkit-lite.nix`
5. Create `nixos/modules/nixos/rknn.nix`
6. Test builds locally with `nix build`

## References

- EZRKNN-Toolkit2: https://github.com/Pelochus/EZRKNN-Toolkit2
- Existing packages: `nixos/pkgs/mali-firmware/`, `nixos/pkgs/orangepi-firmware/`
- Module pattern: `nixos/modules/nixos/services/minio.nix`
- Avalanche CLAUDE.md: Architecture and deployment patterns
