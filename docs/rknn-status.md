# RKNN NPU Integration - Current Status

**Last Updated**: 2025-11-15
**Status**: ⏳ Code Complete - Awaiting Hardware Verification

## Executive Summary

RKNN NPU support for Orange Pi 5 Plus (RK3588) is **foundationally complete and validated**. All code has been implemented, tested with `nix flake check`, and pushed to the repository. The next phase requires hardware deployment and verification.

## What's Been Completed ✅

### Phase 1: Foundation (COMPLETE)

**Nix Packages** (`nixos/pkgs/rknn/`):
- `runtime.nix` - RKNN runtime library (librknnrt.so) + headers
- `toolkit-lite.nix` - Python 3.12 inference API with dependencies
- `default.nix` - Meta-package organizing all components
- **SHA256 hashes verified** for all downloads from EZRKNN-Toolkit2

**NixOS Module** (`nixos/modules/nixos/rknn.nix`):
- Hardware-safe enable flag (guards against non-RK3588)
- Selective component installation options
- Device permissions via udev rules (`/dev/rknpu*`)
- Kernel module loading support
- LD_LIBRARY_PATH configuration
- aarch64-only platform constraint

**Integration & Configuration**:
- `nixos/overlays/rknn-packages.nix` - Exposes RKNN packages
- `nixos/overlays/linux-rknpu.nix` - **NEW: Enables RKNPU in kernel**
- `nixos/overlays/default.nix` - Registers overlays
- `nixos/modules/nixos/default.nix` - Imports RKNN module

**Kernel RKNPU Support** (CODE-LEVEL SOLUTION IMPLEMENTED):
- Added kernel overlay to enable `CONFIG_ROCKCHIP_RKNPU=y`
- Applies to `linux_6_17` (standard nixpkgs, all aarch64)
- Maintains latest security patches
- No vendor kernel needed
- ⚠️ **Still requires hardware deployment & verification**

**Validation**:
- ✅ `nix flake check` passes for all 16 hosts
- ✅ No breaking changes to existing configurations
- ✅ All commits pushed to repository

### Git Commits

1. **d5be9a7** - `feat(rknn): complete Phase 1 - RKNN NPU support foundation`
   - All packages and NixOS module

2. **a7415c9** - `docs: document critical blocker - kernel RKNPU driver not enabled`
   - Discovery and analysis of blocker

3. **f7d13de** - `feat(kernel): enable RKNPU driver support in linux_6_17 kernel`
   - Kernel overlay to enable RKNPU in standard kernel

## What's Documented 📚

### Planning & Design
- `docs/rknn-npu-integration-plan.md` - Overall 4-phase plan with current status
- `docs/rknn-nix-module-design.md` - Detailed architecture and design decisions
- `docs/rknn-investigation-findings.md` - Technical findings and kernel blocker analysis

### Current Status (This Document)
- `docs/rknn-status.md` - Where we are now and what's next

## What's NOT Yet Done (Phase 2+)

### Phase 2: Hardware Deployment & Verification (READY TO START)

**Required Tasks**:
1. Deploy updated configs to opi01-03 nodes
   ```bash
   just nix-deploy opi01
   just nix-deploy opi02
   just nix-deploy opi03
   ```

2. Verify kernel RKNPU support on hardware
   ```bash
   ssh opi01.internal "ls -l /dev/rknpu*"
   ssh opi01.internal "cat /proc/config.gz | gunzip | grep CONFIG_ROCKCHIP_RKNPU"
   ```

3. Once verified:
   - Update `nixos/profiles/role-k3s-worker.nix` to enable RKNN module
   - Choose integration approach:
     - **Option A** (Recommended): Add to existing `role-k3s-worker.nix`
     - **Option B**: Create `role-k3s-worker-npu.nix` variant for selective rollout

4. Test basic RKNN functionality:
   - Python import test: `python3 -c "from rknnlite.api import RKNNLite"`
   - Run example inference (ResNet-18 if available)

### Phase 3: Kubernetes Integration (FUTURE)

- Research K8s device plugin for `/dev/rknpu` access
- Create example RKNN inference workload
- Document deployment patterns

### Phase 4: Documentation (ONGOING)

- Usage guide for RKNN module configuration
- Model conversion workflow documentation
- K8s workload examples

## Architecture Overview

```
Orange Pi 5 Plus (RK3588 SoC with NPU)
    ↓
Linux 6.17 kernel (with CONFIG_ROCKCHIP_RKNPU=y)
    ↓
RKNN Runtime Library (librknnrt.so)
    ↓
RKNN Toolkit Lite (Python API)
    ↓
K3s Workload (future)
```

## Key Files & Locations

### Code
```
nixos/
├── pkgs/rknn/
│   ├── default.nix
│   ├── runtime.nix
│   └── toolkit-lite.nix
├── modules/nixos/
│   └── rknn.nix
└── overlays/
    ├── linux-rknpu.nix
    ├── rknn-packages.nix
    └── default.nix (updated)
```

### Documentation
```
docs/
├── rknn-npu-integration-plan.md
├── rknn-nix-module-design.md
├── rknn-investigation-findings.md
└── rknn-status.md (this file)
```

## Verification Checklist

Before moving to Phase 2:
- [x] RKNN packages created and tested
- [x] NixOS module implemented
- [x] Kernel RKNPU support enabled via overlay
- [x] Flake validation passes
- [x] All code committed and pushed

Before resuming Phase 2:
- [ ] Configs deployed to opi01-03
- [ ] /dev/rknpu* devices present on hardware
- [ ] Kernel config verified: CONFIG_ROCKCHIP_RKNPU=y
- [ ] RKNN module integrates without errors

## Known Limitations & Notes

1. **Kernel Module Loading**: RKNPU driver may load automatically via udev or may need explicit `modprobe rknpu` depending on kernel configuration

2. **Library Path Discovery**: The RKNN Python module needs to find `librknnrt.so` at runtime - this is handled via `LD_LIBRARY_PATH` set in the NixOS module

3. **aarch64 Only**: NPU driver support is architecture-specific (aarch64-linux), guarded in both module and overlay

4. **Orange Pi 5 Plus Specific**: Currently configured for RK3588 (opi01-03 nodes). Other Orange Pi models may need additional kernel options

## Next Steps

1. **Deploy to hardware** when ready:
   ```bash
   just nix-deploy opi01
   just nix-deploy opi02
   just nix-deploy opi03
   ```

2. **Verify on hardware**:
   ```bash
   ssh opi01.internal "ls -l /dev/rknpu*"
   ```

3. **If verified**: Resume Phase 2 integration into `role-k3s-worker.nix`

4. **If issues**: Debug and update kernel overlay as needed

## References

- EZRKNN-Toolkit2: https://github.com/Pelochus/EZRKNN-Toolkit2
- Rockchip RKNN-Toolkit2: https://github.com/airockchip/rknn-toolkit2
- Orange Pi 5 Plus: RK3588 SoC with integrated NPU
- NixOS Kernel Configuration: https://github.com/NixOS/nixpkgs/blob/master/nixos/doc/manual/configuration/linux-kernel.chapter.md

## Questions & Decisions Needed

When resuming work:

1. **Integration approach for Phase 2**:
   - Modify existing `role-k3s-worker.nix`? (Simplest)
   - Create `role-k3s-worker-npu.nix` variant? (More flexible)

2. **Example workload for Phase 3**:
   - ResNet-18 image classification?
   - YOLO object detection?
   - Something else?

3. **Kubernetes device access strategy**:
   - Device plugin?
   - Privileged containers?
   - Hybrid approach?

---

**Current Status**: All code-level work complete and `nix flake check` validated. Kernel RKNPU driver solution implemented in code. **Awaiting hardware deployment and verification** before Phase 2 integration can proceed.

**Blocker Status**: Code-resolved ✅ | Hardware-verified ⏳
