# RKNN Investigation Findings

## Overview

This document summarizes findings from investigating EZRKNN-Toolkit2 binaries and Orange Pi 5 Plus NPU support for the RKNN Nix module integration.

## 1. EZRKNN-Toolkit2 Binary Structure & Sources

### Repository Location
- **Project**: EZRKNN-Toolkit2 (https://github.com/Pelochus/EZRKNN-Toolkit2)
- **Official Source**: Rockchip's RKNN-Toolkit2 (https://github.com/airockchip/rknn-toolkit2)
- **Current Version**: v2.3.2 (released 2025-04-03)

### Component Organization

```
rknpu2/runtime/Linux/librknn_api/
├── aarch64/
│   └── librknnrt.so (7.4 MB) ← For Orange Pi 5 Plus
├── armhf/
│   └── librknnrt.so (4.9 MB)
├── armhf-uclibc/
│   ├── librknnmrt.so (223 KB)
│   └── librknnmrt.a (315 KB)
└── include/
    ├── rknn_api.h
    ├── rknn_custom_op.h
    └── rknn_matmul_api.h

rknn-toolkit-lite2/packages/
└── rknn_toolkit_lite2-2.3.2-cp3{7,8,9,10,11,12}-...-aarch64.whl
    (Multiple wheels for different Python versions)

rknn-toolkit2/packages/arm64/
├── rknn_toolkit2-2.3.2-cp3{6,7,8,9,10,11,12}-...-aarch64.whl
├── arm64_requirements_cp3{6,7,8,9,10,11,12}.txt
└── packages.md5sum
```

### Key Components Needed for Orange Pi

| Component | Purpose | Source | Size |
|-----------|---------|--------|------|
| `librknnrt.so` (aarch64) | NPU runtime library | `rknpu2/runtime/Linux/librknn_api/aarch64/` | 7.4 MB |
| Header files | Development files (rknn_api.h, etc.) | `rknpu2/runtime/Linux/librknn_api/include/` | ~50 KB |
| `rknn-toolkit-lite2-2.3.2-cp3X*-aarch64.whl` | Python inference API | `rknn-toolkit-lite2/packages/` | 500-600 KB each |
| RKNPU kernel module | Kernel driver for NPU | **Not in this repo** | - |
| Python deps (numpy, opencv, etc.) | Wheel dependencies | `rknn-toolkit2/packages/arm64/arm64_requirements_cp3X.txt` | Various |

### Python Support

- **Versions**: 3.7, 3.8, 3.9, 3.10, 3.11, 3.12
- **Wheel format**: manylinux_2_17 (glibc 2.17+) - compatible with Debian 9+, Ubuntu 16.04+
- **Dependencies** (from `arm64_requirements_cp312.txt`):
  ```
  protobuf>=4.21.0,<=4.25.4
  onnx==1.16.1
  onnxruntime>=1.17.0
  torch>=1.13.1,<=2.2.0
  psutil>=5.9.0
  ruamel.yaml>=0.17.21
  scipy>=1.9.3
  tqdm>=4.64.1
  opencv-python>=4.5.5.64
  fast-histogram>=0.11
  Pillow>=10.0.1
  numpy<=1.26.4
  ```

### MD5 Hashes for Integrity

For `rknn-toolkit-lite2-2.3.2` (aarch64):
```
cp37: 24318587c29675dc2e022c08f4581c82
cp38: 9858a6ac17fe698c2bdbf0e58ed291dd
cp39: 69f5bbe44bca65fa2298fd87cf8bc152
cp310: 010dc8d577d91ee779f456ccf9997c7e
cp311: 5da9258e0c69779707e8a06411c398da
cp312: 1abc7ca8e3530f6dba5f51564ed2d6b2
```

### License & Attribution

- **License**: Proprietary Rockchip Electronics Co., Ltd. (2024)
- **Key terms**: "as-is" without warranties, user assumes responsibility for embedded third-party licenses (PyTorch, ONNX, OpenCV, etc.)
- **Attribution required**: Rockchip Electronics Co., Ltd. and the EZRKNN wrapper project

## 2. Orange Pi 5 Plus Kernel NPU Support

### Current Status

**Good news**: The Orange Pi 5 Plus RK3588 kernel includes NPU support.

### Kernel Driver Details

**Driver**: RKNPU (Rockchip NPU kernel driver)
- **Current recommended version**: 0.9.8
- **Minimum supported**: 0.9.6
- **Check version**: `dmesg | grep -i rknpu` or `sudo cat /sys/kernel/debug/rknpu/version`
- **Status**: Already in the kernel on modern Rockchip kernels (6.13+)

### Your Current Kernel Configuration

From `nixos/profiles/hw-orangepi5plus.nix`:
```nix
kernelPackages = pkgs.linuxKernel.packages.linux_6_17;
```

**Kernel version**: Linux 6.17
- **Status**: ✅ Supports RK3588 and NPU drivers (Rockchip support since 6.13)
- **Expected driver availability**: RKNPU driver should be built-in or available as module

### Verification

Device check will happen at runtime:
```bash
# Check if NPU device exists
ls -l /dev/rknpu*

# Check driver loaded
dmesg | grep -i rknpu

# Check device tree
cat /proc/device-tree/compatible
```

### Driver Module Loading

The RKNPU driver is typically:
1. **Built-in** (compiled into kernel) - No action needed
2. **Modular** - Needs `modprobe rknpu` to load (can be added to `boot.kernelModules`)

**For Nix integration**: Should conditionally add `rknpu` to `boot.kernelModules` only on RK3588 hardware.

## 3. Hardware Profile Integration Point

### Current Orange Pi 5 Plus Profile

File: `nixos/profiles/hw-orangepi5plus.nix`

**Current hardware setup** (lines 16-24):
```nix
services.udev.extraRules = ''
  KERNEL=="mpp_service", MODE="0660", GROUP="video"
  KERNEL=="rga", MODE="0660", GROUP="video"
  KERNEL=="system", MODE="0666", GROUP="video"
  # ... more DMA heap rules
'';
```

**Integration point**: Add similar udev rules for `/dev/rknpu*` devices here or in the RKNN module.

### Kernel Module Status

**Lines 88-104** show `initrd.availableKernelModules` - RKNPU is not currently listed (probably built-in).

**Recommendation**: Add to `boot.kernelModules` in RKNN module if needed.

## 4. Implementation Strategy & Packaging Approach

### Pre-built Binary Distribution Plan

**Strategy**: Download pre-built binaries from GitHub releases, package in Nix

**Implementation approach**:

1. **Runtime package** (`rknn-runtime`):
   - Fetch `librknnrt.so` (aarch64) from GitHub
   - Fetch header files
   - Use `fetchurl` with SHA256 hashes
   - Install to standard Nix paths

2. **Python toolkit package** (`rknn-toolkit-lite`):
   - Fetch `.whl` file for Python 3.12 (or version-generic)
   - Or multiple wheels for different Python versions
   - Use `buildPythonPackage` or `python3Packages.buildPythonApplication`
   - Ensure library path discovery at runtime

3. **Dependencies management**:
   - Install Python dependencies from `arm64_requirements_cp312.txt`
   - Handle `torch`, `opencv-python`, `onnxruntime` (may need nixpkgs versions)

### Key Packaging Challenges

1. **librknnrt.so runtime discovery**
   - rknnlite wheel needs to find librknnrt.so at runtime
   - Solution: `LD_LIBRARY_PATH` or `rpath` wrapping
   - Test: `python3 -c "from rknnlite.api import RKNNLite; print('Success')"`

2. **aarch64-only constraint**
   - RKNPU is aarch64-linux only
   - Need platform checks in module and package derivations
   - Use `lib.systems.inspect.patterns.isAarch64`

3. **Kernel module availability**
   - RKNPU driver should be in 6.17 kernel
   - May need explicit module loading configuration
   - Add conditional `boot.kernelModules = lib.mkIf (isRK3588) ["rknpu"]`

4. **Device permissions**
   - `/dev/rknpu*` needs proper access
   - Add udev rules for group/user access
   - Consider video group or dedicated group

## 5. Recommended Packaging Plan

### Phase 1 Implementation Structure

```
nixos/pkgs/rknn/
├── default.nix              # Meta-package
├── runtime.nix              # librknnrt.so + headers
├── toolkit-lite.nix         # Python wheel + dependencies
└── tools.nix               # Optional benchmarks

nixos/modules/nixos/rknn.nix  # Main NixOS module
```

### Binary Sources (for pkg definitions)

**librknnrt.so (aarch64)**:
```
Source: https://github.com/Pelochus/EZRKNN-Toolkit2/raw/main/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so
Size: ~7.4 MB
Location in pkg: lib/
```

**rknn_toolkit_lite2 wheel (Python 3.12)**:
```
Source: https://github.com/Pelochus/EZRKNN-Toolkit2/raw/main/rknn-toolkit-lite2/packages/rknn_toolkit_lite2-2.3.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
MD5: 1abc7ca8e3530f6dba5f51564ed2d6b2
Location in pkg: site-packages/
```

**Header files**:
```
Source: https://github.com/Pelochus/EZRKNN-Toolkit2/tree/main/rknpu2/runtime/Linux/librknn_api/include
Files: rknn_api.h, rknn_custom_op.h, rknn_matmul_api.h
Location in pkg: include/
```

### Python Dependencies

**Approach**: Use nixpkgs Python packages where available, fallback to wheel dependencies listed in `arm64_requirements_cp312.txt`

**Note**: `torch`, `onnxruntime`, `opencv-python` are heavy dependencies. May use pre-built wheels from PyPI rather than building from source.

## 6. Verification Steps

Before implementation:

- [ ] Check if Linux 6.17 in your flake includes RKNPU driver (or if it needs modprobe)
- [ ] Verify GitHub URLs for EZRKNN-Toolkit2 are stable and accessible
- [ ] Confirm MD5 hashes for integrity verification
- [ ] Test librknnrt.so compatibility with your kernel
- [ ] Identify all Python dependencies that need nixpkgs packages vs wheels

## 7. Next Actions

1. **Create** `nixos/pkgs/rknn/runtime.nix` - Package librknnrt.so + headers
2. **Create** `nixos/pkgs/rknn/toolkit-lite.nix` - Package Python wheel + deps
3. **Create** `nixos/modules/nixos/rknn.nix` - NixOS module with device access
4. **Update** `role-k3s-worker.nix` - Enable RKNN module for Orange Pi nodes
5. **Test** - Build and deploy to opi01-03 hardware

## References

- EZRKNN-Toolkit2: https://github.com/Pelochus/EZRKNN-Toolkit2
- Rockchip official RKNN-Toolkit2: https://github.com/airockchip/rknn-toolkit2
- Orange Pi 5 Plus kernel: Uses NixOS linux_6_17 (Rockchip support included)
- NPU Usage Guide: https://hackmd.io/@D6R69BekTZiR1wI7IR7Ntw/S10M_gx2Jg
- Rockchip NPU mainline status: https://blog.tomeuvizoso.net/2024/06/rockchip-npu-update-4-kernel-driver-for.html
