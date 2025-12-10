# RK3588 NPU Integration Plan

## Overview

This document tracks the integration of Rockchip NPU (Neural Processing Unit) support into the Avalanche infrastructure. The goal is to enable hardware-accelerated ML inference on Orange Pi 5 Plus nodes (opi01-03) using the **mainline Linux kernel rocket driver** with **Mesa Teflon** TensorFlow Lite acceleration.

## Context

- **Hardware**: Orange Pi 5 Plus (RK3588 SoC with integrated 6 TOPS NPU)
- **Nodes affected**: opi01-03 (K3s controller nodes)
- **Kernel**: Linux 6.18+ with mainline `rocket` driver
- **Userspace**: Mesa 25.2+ with Teflon TensorFlow Lite delegate
- **Primary use case**: Edge ML inference (computer vision, real-time processing)

## Critical Architecture Decision

### Two Incompatible NPU Stacks

The RK3588 NPU can be accessed through **two mutually exclusive software stacks**:

#### ❌ Vendor Stack (Not Compatible with Mainline Kernel)
- **Kernel**: Rockchip vendor kernel with out-of-tree `rknpu` driver
- **Device**: `/dev/rknpu*`
- **Userspace**: RKNN Toolkit (`librknnrt.so`, rknnlite Python)
- **Models**: `.rknn` format (proprietary quantized models)
- **Status**: ❌ Incompatible with mainline Linux

#### ✅ Mainline Stack (Current Implementation)
- **Kernel**: Mainline Linux 6.18+ with `rocket` driver
- **Device**: `/dev/accel/accel0` (DRM accelerator framework)
- **Userspace**: Mesa Teflon TensorFlow Lite delegate
- **Models**: Standard TFLite `.tflite` format
- **Status**: ✅ Working, actively developed, upstream

**Decision**: Avalanche uses **mainline kernel + Mesa Teflon** to maintain upstream compatibility and avoid vendor lock-in.

## Progress Status

### ✅ Phase 1: Kernel Integration - COMPLETE (2025-12-10)

**Objective**: Enable mainline rocket driver on Orange Pi 5 Plus nodes.

**Deployment Results**:
- Deployed Linux 6.18.0 to opi01-03 (Orange Pi 5 Plus nodes)
- **`rocket` driver loaded successfully** ✅
- All **3 NPU cores detected** and initialized:
  ```
  [   16.974889] rocket fdab0000.npu: Rockchip NPU core 0 version: 1179210309
  [   16.991713] rocket fdac0000.npu: Rockchip NPU core 1 version: 1179210309
  [   17.005136] rocket fdad0000.npu: Rockchip NPU core 2 version: 1179210309
  ```
- NPU device exposed via DRM accelerator framework: `/dev/accel/accel0` ✅
- Device permissions configured (mode 0666, group render)
- Mesa 25.2.6 with Teflon delegate installed: `/nix/store/.../lib/libteflon.so` ✅

**Completed:**
- [x] Updated `nixos/profiles/hw-orangepi5plus.nix` to kernel 6.18
- [x] Deployed to all opi01-03 nodes
- [x] Verified rocket driver loads and detects 3 NPU cores
- [x] Confirmed `/dev/accel/accel0` device accessible to render group
- [x] Verified Mesa Teflon delegate is available

**Verification Commands**:
```bash
# Check kernel and driver
ssh opi01.internal 'uname -r'  # Should show 6.18.0
ssh opi01.internal 'lsmod | grep rocket'  # Should show rocket module

# Check NPU device
ssh opi01.internal 'ls -la /dev/accel/accel0'

# Check NPU cores detected
ssh opi01.internal 'sudo dmesg | grep "rocket.*npu"'

# Verify Mesa Teflon
ssh opi01.internal 'find /nix/store -name "libteflon.so" 2>/dev/null | head -1'
```

### 🔄 Phase 2: TensorFlow Lite + Teflon Testing - IN PROGRESS

**Objective**: Validate NPU acceleration with TensorFlow Lite models.

**Current Status**: Ready for testing, Mesa Teflon installed.

#### 2.1 Setup TensorFlow Lite Runtime
- [ ] Install tflite-runtime Python package on Orange Pi nodes
- [ ] Download test models (MobileNetV1, SSDLite MobileDet)
- [ ] Create basic inference test script

#### 2.2 Test NPU Acceleration
- [ ] Run MobileNetV1 inference with Teflon delegate
- [ ] Verify NPU is being used (not CPU fallback)
- [ ] Benchmark inference latency (target: <50ms for MobileNetV1)
- [ ] Test object detection (SSDLite MobileDet, target: 30 FPS)

#### 2.3 Validate Multi-Core Support
- [ ] Test single-core vs multi-core performance
- [ ] Verify all 3 NPU cores are accessible
- [ ] Document performance scaling

**Testing Guide**:

1. **Install TFLite Runtime**:
```bash
ssh opi01.internal
python -m pip install --user tflite-runtime==2.13.0 pillow numpy
```

2. **Download MobileNetV1 Model**:
```bash
wget https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz
tar -xzf mobilenet_v1_1.0_224_quant.tgz
```

3. **Create Test Script** (`tflite-npu-test.py`):
```python
#!/usr/bin/env python3
import tflite_runtime.interpreter as tflite
import numpy as np
import time
import subprocess

# Find libteflon.so
result = subprocess.run(
    ['find', '/nix/store', '-name', 'libteflon.so'],
    capture_output=True, text=True
)
TEFLON_LIB = result.stdout.strip().split('\n')[0]
print(f"Using Teflon delegate: {TEFLON_LIB}")

# Create interpreter with Teflon delegate
delegates = [tflite.load_delegate(TEFLON_LIB)]
interpreter = tflite.Interpreter(
    model_path="mobilenet_v1_1.0_224_quant.tflite",
    experimental_delegates=delegates
)

interpreter.allocate_tensors()

# Get input/output details
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

# Create dummy input (224x224x3 uint8 for MobileNetV1)
input_shape = input_details[0]['shape']
dummy_input = np.random.randint(0, 256, input_shape, dtype=np.uint8)

# Warm-up run
interpreter.set_tensor(input_details[0]['index'], dummy_input)
interpreter.invoke()

# Benchmark 10 inferences
print("Running 10 inference iterations...")
times = []
for i in range(10):
    start = time.time()
    interpreter.set_tensor(input_details[0]['index'], dummy_input)
    interpreter.invoke()
    output = interpreter.get_tensor(output_details[0]['index'])
    elapsed = (time.time() - start) * 1000
    times.append(elapsed)
    print(f"  Iteration {i+1}: {elapsed:.2f}ms")

avg_time = sum(times) / len(times)
print(f"\n✓ Average inference time: {avg_time:.2f}ms")
print(f"✓ Output shape: {output.shape}")
```

4. **Run with Debug Output**:
```bash
TEFLON_DEBUG=verbose python tflite-npu-test.py
```

### Phase 3: Kubernetes Integration

**Objective**: Enable K8s workloads to use the NPU.

**STATUS**: ⏳ PENDING - After Phase 2 testing

#### 3.1 Research NPU Device Access
- [ ] Investigate Kubernetes device plugin architecture for DRM accel devices
- [ ] Determine `/dev/accel/accel0` exposure strategy
  - Option A: Device plugin for managed access
  - Option B: Privileged containers with device mounts
  - Option C: hostPath volumes for `/dev/accel/*`
- [ ] Plan security model and access control

#### 3.2 Create Example Workload
- [ ] Build container image with TFLite + Mesa Teflon
- [ ] Package MobileNetV1 or MobileDet model
- [ ] Deploy as K8s Deployment/Pod with NPU access
- [ ] Create HTTP inference service (REST API)
- [ ] Demonstrate end-to-end: HTTP request → NPU inference → response

### Phase 4: Documentation

**Objective**: Document for future reference and community contribution.

**STATUS**: 📝 ONGOING

#### 4.1 Document Usage
- [x] Document kernel driver compatibility (this doc)
- [x] Document Mesa Teflon approach vs RKNN Toolkit
- [ ] Write "TFLite NPU Usage Guide"
  - How to install TFLite runtime
  - How to load Teflon delegate
  - Supported models and operations
- [ ] Document model selection and optimization
  - Supported TFLite operations (convolutions, additions, ReLU)
  - Unsupported operations (SiLU, etc.)
  - Quantization requirements (int8 quantized models)
- [ ] Write "Kubernetes NPU Workloads" guide
  - Container image setup
  - Device access configuration
  - Performance tuning

#### 4.2 Optional Community Contribution
- [ ] Share findings with NixOS community
- [ ] Document Mesa Teflon integration patterns for NixOS

## Technical Details

### Hardware Specifications

**RK3588 NPU**:
- Architecture: 3 independent NPU cores
- Performance: 6 TOPS combined (2 TOPS per core)
- Precision: INT8/INT16 quantized inference
- Framework: DRM accelerator subsystem (`/dev/accel/accel0`)

### Mainline Rocket Driver

**Kernel Driver** (merged in Linux 6.18):
- Module: `drivers/accel/rocket/`
- Config: `DRM_ACCEL_ROCKET=y`
- Dependencies: `ARCH_ROCKCHIP`, `ARM64`, `ROCKCHIP_IOMMU`, `MMU`
- Device exposure: `/dev/accel/accel*` (via DRM framework)
- Userspace API: `include/uapi/drm/rocket_accel.h`

**Development**: Developed by Tomeu Vizoso (Collabora) based on reverse-engineered NPU information.

### Mesa Teflon TensorFlow Lite Delegate

**Mesa Teflon** (merged in Mesa 24.1):
- Type: TensorFlow Lite external delegate
- Location: `lib/libteflon.so`
- Framework: Gallium3D frontend
- Supported drivers: `etnaviv`, `rocket`
- Auto-discovery: TFLite runtime loads delegate automatically

**Supported Operations** (as of 2025-07):
- Convolutions (most configurations)
- Tensor additions
- ReLU activation (fused with convolutions)

**Unsupported Operations**:
- SiLU activation (blocks YOLOv8)
- Various other ops (check Mesa docs for current status)

**Proven Models**:
- ✅ MobileNetV1/V2 (image classification)
- ✅ SSDLite MobileDet (object detection, 30 FPS @ 1 core)

**Performance**:
- MobileNetV1 inference: ~16-21ms (target)
- Comparable to vendor RKNN performance in tested models
- Active optimization ongoing

### Model Format Requirements

**Input**: Standard TensorFlow Lite `.tflite` models
- **Must be quantized**: INT8 or INT16 (float32 falls back to CPU)
- **Supported conversions**: TensorFlow → TFLite, PyTorch → ONNX → TFLite, etc.
- **Tools**: TensorFlow Lite Converter, tf2onnx, ONNX-TFLite converter

**Example Conversion** (TensorFlow):
```python
import tensorflow as tf

# Convert with quantization
converter = tf.lite.TFLiteConverter.from_saved_model('model/')
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.target_spec.supported_types = [tf.int8]
tflite_model = converter.convert()

with open('model_quant.tflite', 'wb') as f:
    f.write(tflite_model)
```

## Success Criteria

- [x] Kernel 6.18+ deployed with rocket driver ✅
- [x] opi01-03 nodes detect NPU hardware and expose `/dev/accel/accel0` ✅
- [x] Mesa Teflon delegate installed and available ✅
- [ ] TFLite runtime can load Teflon and run inference on NPU
- [ ] MobileNetV1 inference achieves <50ms latency
- [ ] Object detection achieves ≥30 FPS
- [ ] Kubernetes pods can access NPU hardware
- [ ] Documentation enables others to build TFLite NPU workloads
- [ ] Example workload demonstrates realistic usage

## Timeline

No specific deadline. Phases can be pursued at own pace:
- Phase 1: Kernel integration (✅ COMPLETE - 2025-12-10)
- Phase 2: TFLite + Teflon testing (🔄 IN PROGRESS - 2025-12-10)
- Phase 3: K8s integration (⏳ PENDING)
- Phase 4: Documentation (📝 ONGOING)

## Related Issues & References

### Primary References
- [Mesa Teflon Documentation](https://docs.mesa3d.org/teflon.html)
- [Tomeu Vizoso: Rockchip NPU Update 6 - We are in mainline!](https://blog.tomeuvizoso.net/2025/07/rockchip-npu-update-6-we-are-in-mainline.html)
- [Tomeu Vizoso: Real-time object detection on RK3588](https://blog.tomeuvizoso.net/2024/04/rockchip-npu-update-3-real-time-object.html)
- [Collabora: RK3588 Upstream Support Progress](https://www.collabora.com/news-and-blog/news-and-events/rockchip-rk3588-upstream-support-progress-future-plans.html)
- [Phoronix: Rocket Accelerator Driver Posted](https://www.phoronix.com/news/Rocket-Rockchip-NPU-Driver)
- [Mesa GitLab: Rocket Driver MR](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/29698)

### Kernel References
- Kernel source: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
  - Branch: v6.18+ (has DRM_ACCEL_ROCKET)
  - Driver: `drivers/accel/rocket/`

### TensorFlow Lite Resources
- [TensorFlow Lite Guide](https://www.tensorflow.org/lite/guide)
- [TFLite Model Garden](https://www.tensorflow.org/lite/models)
- [TFLite Python Quickstart](https://www.tensorflow.org/lite/guide/python)

## Historical Notes

### Initial RKNN Toolkit Exploration (2025-11-15)

**What was attempted**: Integration of Rockchip's vendor RKNN Toolkit (librknnrt.so, rknnlite Python) based on [EZRKNN-Toolkit2](https://github.com/Pelochus/EZRKNN-Toolkit2).

**Why it didn't work**: The vendor RKNN Toolkit requires Rockchip's out-of-tree `rknpu` kernel driver which exposes `/dev/rknpu*` devices. This driver is incompatible with the mainline `rocket` driver which uses the DRM accelerator framework (`/dev/accel/*`). The RKNN userspace libraries cannot communicate with the rocket driver.

**Artifacts created** (now obsolete):
- `nixos/pkgs/rknn/runtime.nix` - librknnrt.so (incompatible with rocket driver)
- `nixos/pkgs/rknn/toolkit-lite.nix` - rknnlite Python wheel (incompatible)
- `nixos/pkgs/rknn/default.nix` - Meta-package
- `nixos/modules/nixos/rknn.nix` - NixOS module (to be removed/repurposed)
- `nixos/overlays/rknn-packages.nix` - Package overlay (to be removed)

**Resolution**: Pivoted to Mesa Teflon approach to maintain mainline kernel compatibility.

### Vendor RKNN Toolkit Reference (For Comparison)

If using vendor kernel with `rknpu` driver, the RKNN Toolkit would provide:

**Python API**:
```python
from rknnlite.api import RKNNLite

rknn = RKNNLite()
rknn.load_rknn('model.rknn')  # Proprietary .rknn format
rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0)
outputs = rknn.inference(inputs=[image_data])
rknn.release()
```

**Performance Claims**:
- ResNet-18 inference: ~71ms on RK3588 NPU
- 10-100x faster than CPU-only inference

**Model Formats**: Requires conversion to proprietary `.rknn` format using RKNN Toolkit (desktop tool).

**Why We Don't Use This**: Requires vendor kernel, not upstream-compatible, vendor lock-in.

## Next Actions

1. **Immediate** (Phase 2):
   - Install tflite-runtime on opi01
   - Download MobileNetV1 quantized model
   - Run basic inference test with Teflon delegate
   - Verify NPU acceleration is working
   - Benchmark performance

2. **Short-term**:
   - Test object detection with SSDLite MobileDet
   - Validate multi-core performance
   - Create containerized TFLite inference service

3. **Long-term**:
   - Design Kubernetes device plugin for `/dev/accel/accel0`
   - Build production-ready inference service
   - Deploy to K8s cluster with NPU access
   - Document end-to-end workflow

## Notes

- This is exploratory; no immediate production use cases
- NPU support is different from Ollama (LLM inference) - focused on computer vision and general ML
- Mainline approach ensures long-term support and community contributions
- Mesa Teflon is actively developed; expect operation coverage to expand
- Performance optimization is ongoing; may not yet match vendor driver in all scenarios
- For models requiring unsupported operations, CPU fallback occurs automatically
