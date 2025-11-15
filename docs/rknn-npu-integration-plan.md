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

All foundation work is complete and flake validation passes.

**Completed:**
- [x] Design Architecture - See `docs/rknn-nix-module-design.md`
- [x] Investigation & Findings - See `docs/rknn-investigation-findings.md`
- [x] Create `nixos/pkgs/rknn/runtime.nix` - librknnrt.so + headers from EZRKNN-Toolkit2
- [x] Create `nixos/pkgs/rknn/toolkit-lite.nix` - Python 3.12 wheel + dependencies
- [x] Create `nixos/pkgs/rknn/default.nix` - Meta-package
- [x] Create `nixos/modules/nixos/rknn.nix` - Full NixOS module with:
  - Conditional enable flag (hardware-safe)
  - Selective component installation
  - Device permissions via udev rules
  - Kernel module loading support
  - LD_LIBRARY_PATH configuration
  - aarch64-only guard
- [x] Add RKNN overlay to `nixos/overlays/default.nix`
- [x] Register RKNN module in `nixos/modules/nixos/default.nix`
- [x] Validate with `nix flake check` - All 16 hosts pass ✅

## Implementation Plan

### Phase 1: Foundation - Nix Packaging & Module

**Objective**: Get RKNN components packaged in Nix and create a reusable module

**STATUS**: ✅ COMPLETE

#### 1.1 Design Architecture
- [x] Determine packaging strategy (pre-built binaries vs. building from source)
- [x] Plan library/header installation strategy
- [x] Design Python bindings packaging approach
- [x] Document dependency tree and system requirements

#### 1.2 Create Nix Packages
- [x] Create `rknn-runtime` package (RKNN library and headers)
- [x] Create `rknn-toolkit-lite` package (Python inference library)
- [x] Package supporting tools (RKNN benchmark, utilities)
- [x] Handle architecture-specific binaries (aarch64 only)

#### 1.3 Create NixOS Module
- [x] Create `nixos/modules/nixos/rknn.nix`
  - Package installation
  - Environment variable setup
  - Kernel driver configuration (if needed)
  - Configuration options (enable/disable, core selection)
- [x] Integration hooks for hardware profiles

### Phase 2: Integration into Orange Pi Profile

**Objective**: Make NPU available to K3s worker nodes

**STATUS**: 🚫 BLOCKED - Kernel RKNPU Driver Not Enabled

**BLOCKER** (discovered 2025-11-15):
The Linux 6.17 kernel on opi01-03 does NOT have RKNPU driver support compiled in.
- No `/dev/rknpu*` devices present
- `CONFIG_ROCKCHIP_RKNPU` not in kernel config
- See `docs/rknn-investigation-findings.md` § 3 for details and solution paths

**Solution required before Phase 2 can proceed:**
- Option A: Enable RKNPU in standard nixpkgs kernel (requires kernel config modification)
- Option B: Switch to custom vendor kernel with RKNPU enabled
- Option C: Build out-of-tree RKNPU module (complex, not recommended)

**Blocking tasks:**
1. Decide on kernel solution approach
2. Implement kernel changes (whichever option chosen)
3. Rebuild and redeploy to opi01-03
4. Verify `/dev/rknpu*` devices appear
5. Resume Phase 2 integration

#### 2.1 Integrate into K3s Worker Profile
- [ ] Update `nixos/profiles/role-k3s-worker.nix` OR create variant
- [ ] Enable RKNN module conditionally for opi nodes
- [ ] Ensure device permissions are properly configured
- [ ] Handle NPU device (`/dev/rknpu*`) access

#### 2.2 Test on Hardware
- [ ] Deploy to opi01-03 nodes
- [ ] Verify RKNN runtime loads correctly
- [ ] Test basic inference (ResNet-18 example from EZRKNN-Toolkit2)
- [ ] Benchmark inference performance
- [ ] Validate NPU core selection and utilization

### Phase 3: Kubernetes Integration

**Objective**: Enable K8s workloads to use the NPU

**STATUS**: ⏳ PENDING - After Phase 2

#### 3.1 Research NPU Device Access
- [ ] Investigate Kubernetes device plugin architecture
- [ ] Determine `/dev/rknpu` exposure strategy
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
  - How to enable for a node/profile
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
- [ ] opi01-03 nodes can load and run RKNN models
- [ ] Kubernetes pods can access NPU hardware
- [ ] Documentation enables others to build RKNN workloads
- [ ] Example workload demonstrates realistic usage

## Timeline

No specific deadline. Phases can be pursued at own pace:
- Phase 1: Foundation (highest priority)
- Phase 2: Hardware validation
- Phase 3: K8s integration (nice-to-have initially)
- Phase 4: Documentation (ongoing)

## Related Issues & References

- EZRKNN-Toolkit2: https://github.com/Pelochus/EZRKNN-Toolkit2
- Official RKNN-Toolkit2: https://github.com/airockchip/rknn-toolkit2
- Rockchip RK3588 specs: Orange Pi 5 Plus hardware
- CLAUDE.md: Avalanche architecture and deployment patterns

## Notes

- This is exploratory; no immediate production use cases
- NPU support is different from Ollama (LLM inference) - focused on computer vision and general ML
- Nix packaging is the main challenge; hardware integration should be straightforward
- Kernel driver may be needed for device access - investigate during Phase 1
