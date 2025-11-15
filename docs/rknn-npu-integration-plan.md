# RKNN NPU Integration Plan

## Overview

This document tracks the integration of Rockchip NPU (Neural Processing Unit) support into the Avalanche infrastructure. The goal is to enable hardware-accelerated ML inference on Orange Pi 5 Plus nodes (opi01-03) via the RKNN Toolkit.

## Context

- **Hardware**: Orange Pi 5 Plus (RK3588 SoC with integrated NPU)
- **Nodes affected**: opi01-03 (K3s worker nodes)
- **Reference project**: [EZRKNN-Toolkit2](https://github.com/Pelochus/EZRKNN-Toolkit2)
- **Primary use case**: Edge ML inference (computer vision, real-time processing)

## Architecture Approach

- Use **NixOS modules** (not personalities) for flexibility
- Integrate into `nixos/profiles/role-k3s-worker.nix` or create a variant
- Enable opt-in NPU access for Kubernetes workloads
- No immediate use cases; foundation for future development

## Progress Status

### ✅ Phase 1: COMPLETE (2025-11-15)

All foundation work is complete. Code is in place but disabled until kernel support is available.

**Completed:**
- [x] Design Architecture
- [x] Investigation & Findings - RKNPU not in linux_6_17, but found in linux 6.18-rc5
- [x] Create `nixos/pkgs/rknn/runtime.nix` - librknnrt.so + headers from EZRKNN-Toolkit2
- [x] Create `nixos/pkgs/rknn/toolkit-lite.nix` - Python 3.12 wheel + dependencies
- [x] Create `nixos/pkgs/rknn/default.nix` - Meta-package
- [x] Create `nixos/modules/nixos/rknn.nix` - Full NixOS module with:
  - Conditional enable flag (disabled by default, hardware-safe)
  - Selective component installation
  - Device permissions via udev rules
  - Kernel module loading support
  - LD_LIBRARY_PATH configuration
  - aarch64-only guard
- [x] Create `nixos/overlays/rknn-packages.nix` - Package overlay (not auto-imported)

**Status**: Code is present but NOT imported in default overlays/modules - safe to keep.

### 🚫 Phase 2: BLOCKED - Waiting for Kernel 6.18

**Current Blocker**: Linux 6.17 (current stable) doesn't have RKNPU kernel driver support.

**Investigation Results** (2025-11-15):
- Analyzed linux-6.17 official kernel source: **NO RKNPU driver present**
- Found in linux-6.18-rc5: **`DRM_ACCEL_ROCKET` driver framework** ✅
  - Config option: `CONFIG_DRM_ACCEL_ROCKET` (tristate)
  - Depends on: `ARCH_ROCKCHIP && ARM64` (✅ matches RK3588)
  - Module name: `rocket`
  - Full driver implementation in `drivers/accel/rocket/` with complete source
  - Exposed via DRM accelerator framework to userspace
  - Used by Rocket userspace driver in Mesa3D

**Timeline**:
- linux 6.18-rc5: Released 2025-11-09 (current RC phase)
- linux 6.18 stable: Expected ~December 2025 (estimated)
- nixpkgs availability: Likely 1-2 months after kernel release

**Blocking tasks** (resume when kernel 6.18 is in nixpkgs):
1. Update `nixos/profiles/hw-orangepi5plus.nix` to use linux_6.18+ (when available)
2. Enable `CONFIG_DRM_ACCEL_ROCKET=y` in kernel config overlay
3. Rebuild and redeploy to opi01-03
4. Verify `/dev/drm/accel/accel*` devices appear
5. Resume Phase 2 integration

#### 2.1 Integrate into K3s Worker Profile
- [ ] Update `nixos/profiles/role-k3s-worker.nix` OR create variant
- [ ] Enable RKNN module conditionally for opi nodes
- [ ] Ensure device permissions are properly configured
- [ ] Handle NPU device (`/dev/drm/accel/accel*`) access

#### 2.2 Test on Hardware
- [ ] Deploy to opi01-03 nodes (once kernel 6.18 available)
- [ ] Verify RKNN runtime loads correctly
- [ ] Test basic inference (ResNet-18 example from EZRKNN-Toolkit2)
- [ ] Benchmark inference performance
- [ ] Validate NPU core selection and utilization

### Phase 3: Kubernetes Integration

**Objective**: Enable K8s workloads to use the NPU

**STATUS**: ⏳ PENDING - After Phase 2

#### 3.1 Research NPU Device Access
- [ ] Investigate Kubernetes device plugin architecture for DRM accel devices
- [ ] Determine `/dev/drm/accel` exposure strategy
  - Option A: Device plugin for managed access
  - Option B: Privileged containers with device mounts
  - Option C: Hybrid approach
- [ ] Plan security model and access control

#### 3.2 Create Example Workload
- [ ] Build sample RKNN inference service
  - Image classification (ResNet-18)
  - Or object detection (YOLO)
- [ ] Deploy as K8s Deployment/Pod
- [ ] Document model conversion workflow
- [ ] Demonstrate end-to-end: model → Kubernetes → NPU inference

### Phase 4: Documentation

**Objective**: Document for future reference and community contribution

**STATUS**: ⏳ PENDING - Ongoing

#### 4.1 Document Usage
- [ ] Write "RKNN Module Usage Guide"
  - How to enable for a node/profile (once kernel available)
  - Configuration options
  - Dependency management
- [ ] Document model conversion workflow
  - Supported input formats (ONNX, TensorFlow, PyTorch, etc.)
  - Conversion tools and process
  - Optimization strategies
- [ ] Write "Kubernetes RKNN Workloads" guide
  - How to build RKNN inference apps
  - Device access from containers
  - Performance tuning
- [ ] Create troubleshooting guide
  - Common issues and solutions
  - Runtime version mismatches
  - Device access problems

#### 4.2 Optional Community Contribution
- [ ] Consider contributing RKNN packages to nixpkgs
- [ ] Share module patterns with NixOS community if beneficial

## Technical Details

### RKNPU Kernel Driver History

**linux 6.17 and earlier**: No RKNPU support
- Submitted to kernel mailing list: June 2024
- Target: linux 6.18+
- Framework: DRM accelerator (DRM_ACCEL)

**linux 6.18-rc5** (current as of 2025-11-09):
- Driver: `drivers/accel/rocket/` - fully implemented
- Config: `DRM_ACCEL_ROCKET` (tristate: y/m/n)
- Dependencies: `ARCH_ROCKCHIP`, `ARM64`, `ROCKCHIP_IOMMU`, `MMU`
- Device exposure: `/dev/drm/accel/accel*` (via DRM framework)
- Userspace API: `include/uapi/drm/rocket_accel.h`
- Integration: Used by Mesa3D Rocket userspace driver

### Supported Model Formats (via RKNN Toolkit)

Conversion support (on desktop/PC):
- TensorFlow / TensorFlow Lite
- PyTorch (via ONNX)
- ONNX
- Caffe
- Darknet

Output: Quantized `.rknn` model files optimized for RK3588

### Inference APIs

**Python** (RKNN-Toolkit-Lite2):
```python
from rknnlite.api import RKNNLite

rknn = RKNNLite()
rknn.load_rknn('model.rknn')
rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0)
outputs = rknn.inference(inputs=[image_data])
rknn.release()
```

**C/C++**: RKNN Runtime APIs available via `librknnrt.so`

### Performance Characteristics

- ResNet-18 inference: ~71ms on RK3588 NPU
- 10-100x faster than CPU-only inference
- Energy efficient compared to CPU computation
- NPU cores can be selected (core_mask parameter)

## Success Criteria

- [ ] RKNN module is reproducible and maintainable in Nix
- [ ] Kernel 6.18+ is available in nixpkgs with DRM_ACCEL_ROCKET enabled
- [ ] opi01-03 nodes can load and run RKNN models
- [ ] Kubernetes pods can access NPU hardware
- [ ] Documentation enables others to build RKNN workloads
- [ ] Example workload demonstrates realistic usage

## Timeline

No specific deadline. Phases can be pursued at own pace:
- Phase 1: Foundation (✅ COMPLETE - code ready, waiting for kernel)
- Phase 2: Hardware validation (waiting for kernel 6.18 in nixpkgs)
- Phase 3: K8s integration (nice-to-have initially)
- Phase 4: Documentation (ongoing)

## Related Issues & References

- EZRKNN-Toolkit2: https://github.com/Pelochus/EZRKNN-Toolkit2
- Official RKNN-Toolkit2: https://github.com/airockchip/rknn-toolkit2
- Rockchip RK3588 specs: Orange Pi 5 Plus hardware
- CLAUDE.md: Avalanche architecture and deployment patterns
- Kernel source: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
  - Branch: v6.18-rc5 (has DRM_ACCEL_ROCKET)
  - Branch: v6.17 (no RKNPU support)

## Notes

- This is exploratory; no immediate production use cases
- NPU support is different from Ollama (LLM inference) - focused on computer vision and general ML
- Phase 1 code is complete and maintainable - ready for Phase 2 once kernel 6.18 is available
- Kernel evolution: RKNPU driver was only submitted to mainline in June 2024, targeting 6.18+
- Next action: Monitor nixpkgs for linux 6.18+ availability, then re-enable integration
