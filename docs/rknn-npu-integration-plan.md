# RK3588 NPU Integration Plan

## Overview

This document tracks the integration of Rockchip NPU (Neural Processing Unit) support into the Avalanche infrastructure. The goal is to enable hardware-accelerated ML inference on Orange Pi 5 Plus nodes (opi01-03) using the **mainline Linux kernel rocket driver** with **Mesa Teflon** TensorFlow Lite acceleration.

## Context

- **Hardware**: Orange Pi 5 Plus (RK3588 SoC with integrated 6 TOPS NPU)
- **Nodes affected**: opi01-03 (K3s controller nodes)
- **Kernel**: Linux 6.18+ with mainline `rocket` driver
- **Userspace**: Mesa 25.3+ with Teflon TensorFlow Lite delegate (rocket driver added in 25.3)
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
- Mesa 25.3.x (from nixpkgs-unstable) with rocket Gallium driver and Teflon delegate ✅

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

### ✅ Phase 2: TensorFlow Lite + Teflon Testing - COMPLETE (2025-12-11)

**Objective**: Validate NPU acceleration with TensorFlow Lite models.

**Current Status**: Successfully validated NPU acceleration with excellent performance.

**Key Discovery (2025-12-10)**:
Mesa 25.3+ is **required** for rocket Gallium driver support. The rocket driver was merged into Mesa 25.3 in October 2025. Earlier versions (25.2.x) do not include the rocket driver, causing "Couldn't open kernel device" errors when Teflon attempts to access the NPU.

**Configuration Changes (2025-12-10)**:
- [x] Upgraded Mesa to 25.3.x from nixpkgs-unstable (includes rocket Gallium driver)
- [x] Upgraded Python + TensorFlow from nixpkgs-unstable for compatibility
- [x] Added Python with numpy, pillow, tensorflow-bin to opi01-03
- [x] Added user to `render` group for `/dev/accel/accel0` access
- [x] Created udev rule: `/dev/dri/renderD180` → `/dev/accel/accel0` symlink (for Mesa Teflon device discovery)
- [x] Created test script `scripts/npu/tflite-npu-test.py` with automatic Teflon library detection

**Test Results (2025-12-11)**:
- [x] Mesa 25.3.1 successfully deployed and active on opi01
- [x] Teflon delegate loads from `/run/opengl-driver/lib/libteflon.so`
- [x] MobileNetV1 quantized model inference working on NPU
- [x] **Performance: Average 13.66ms** (min: 11.84ms, max: 17.00ms)
- [x] Performance meets target (<50ms) ✅
- [x] Performance within expected range (16-21ms) ✅

**Test Script Improvements (2025-12-11)**:
- [x] Fixed library detection to prioritize `/run/opengl-driver` (canonical location)
- [x] Added fallback to query current system closure via `nix-store -qR`
- [x] Script correctly finds Mesa 25.3.1 on deployed system

#### 2.1 Setup TensorFlow Lite Runtime
- [x] Install TensorFlow Lite on Orange Pi nodes (via NixOS configuration)
- [x] Download test models (MobileNetV1 ✅)
- [x] Create basic inference test script (`tflite-npu-test.py`)

#### 2.2 Test NPU Acceleration
- [x] Run MobileNetV1 inference with Teflon delegate ✅
- [x] Verify NPU is being used (13.66ms avg proves hardware acceleration) ✅
- [x] Benchmark inference latency (13.66ms - exceeds <50ms target) ✅
- [ ] Test object detection (SSDLite MobileDet, target: 30 FPS) - Optional

#### 2.3 Validate Multi-Core Support
- [ ] Test single-core vs multi-core performance - Future work
- [ ] Verify all 3 NPU cores are accessible - Future work
- [ ] Document performance scaling - Future work

**Testing Guide**:

1. **Prerequisites** (already configured via NixOS):
   - Python 3 with numpy, pillow, tensorflow-bin (from nixpkgs-unstable)
   - Mesa 25.3.x with rocket Gallium driver and Teflon delegate
   - User in `render` group for NPU access
   - udev rule creating `/dev/dri/renderD180` symlink

2. **Download MobileNetV1 Model**:
```bash
ssh opi01.internal
cd ~
wget https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz
tar -xzf mobilenet_v1_1.0_224_quant.tgz
```

3. **Run Test Script**:
The test script is available at `scripts/npu/tflite-npu-test.py` in the repository.

```bash
# Run with debug output to see Teflon logs
TEFLON_DEBUG=verbose python3 ~/tflite-npu-test.py

# Or run normally
python3 ~/tflite-npu-test.py
```

The script will:
- Automatically find and load the Teflon delegate from current system Mesa
- Load MobileNetV1 quantized model
- Run 10 inference iterations with random input
- Report average inference time (target: <50ms, ideal: 16-21ms)
- Indicate success if performance meets expectations

4. **Verify NPU Usage**:
Check kernel logs for NPU activity during inference:
```bash
sudo dmesg -w | grep -i rocket
```

### Phase 3: Kubernetes Integration

**Objective**: Enable K8s workloads to use the NPU.

**STATUS**: 🚧 IN PROGRESS - Phase 3.1 & 3.2 complete, 3.3 pending

#### Overview

Phase 3 focuses on making the RK3588 NPU accessible to Kubernetes workloads running on the K3s cluster. This involves three key challenges:

1. **Device Access**: Exposing `/dev/accel/accel0` to containers
2. **Container Image**: Building images with Mesa Teflon + TensorFlow Lite
3. **Workload Deployment**: Creating example inference services

#### ⚠️ NixOS-Specific Requirements

**Critical Discovery** (2025-12-11): When running NPU containers on NixOS hosts, you **must** mount both:

1. `/run/opengl-driver/lib` → Container mount point for Mesa libraries
2. `/nix/store` → Required because libraries in `/run/opengl-driver/lib` are symlinks pointing to `/nix/store`

**Why both are needed**:
- `/run/opengl-driver/lib/libteflon.so` is a symlink to `/nix/store/...-mesa-25.3.1/lib/libteflon.so`
- Without `/nix/store` mount, the symlink exists but points to an inaccessible path
- Result: "Could not find libteflon.so" error even though symlink is visible

**Correct volume mounts for NixOS**:
```yaml
volumeMounts:
- name: mesa-libs
  mountPath: /mesa-libs
  readOnly: true
- name: nix-store
  mountPath: /nix/store
  readOnly: true

volumes:
- name: mesa-libs
  hostPath:
    path: /run/opengl-driver/lib
- name: nix-store
  hostPath:
    path: /nix/store
```

**Non-NixOS hosts** (Debian, Ubuntu, etc.) only need the Mesa library directory mount, as libraries are typically in `/usr/lib` without symlinks.

#### 3.1 Research & Design NPU Device Access

**Goal**: Determine the best approach for exposing `/dev/accel/accel0` to pods.

**Device Access Options**:

**Option A: Kubernetes Device Plugin** (Recommended for Production)
- **Pros**:
  - Proper resource scheduling (K8s tracks NPU availability)
  - Native resource requests/limits (`resources.limits.npu.rockchip.com/rk3588: 1`)
  - Multi-tenant scheduling (prevents NPU oversubscription)
  - Clean abstraction (pods don't need to know device path)
- **Cons**:
  - Requires custom device plugin development/deployment
  - More complex initial setup
  - Overhead for single-user clusters
- **Implementation**:
  - Create device plugin DaemonSet on opi01-03 nodes
  - Plugin advertises `/dev/accel/accel0` as `npu.rockchip.com/rk3588: 3` (3 cores)
  - Pods request NPU: `resources.limits.npu.rockchip.com/rk3588: 1`
  - Plugin mounts `/dev/accel/accel0` + `/dev/dri/renderD180` into pod
  - Also mount `/run/opengl-driver/lib` for Mesa Teflon libraries

**Option B: Privileged Container + Device Mount** (Quick Testing)
- **Pros**:
  - Simple to implement (no device plugin needed)
  - Good for initial testing and development
  - Direct control over device access
- **Cons**:
  - Requires `privileged: true` or `hostPath` volumes (security concern)
  - No resource tracking (K8s doesn't know NPU is in use)
  - Manual device conflicts (two pods could try to use NPU simultaneously)
- **Implementation**:
  ```yaml
  spec:
    containers:
    - name: inference
      securityContext:
        privileged: true
      volumeMounts:
      - name: npu-device
        mountPath: /dev/accel
      - name: dri-device
        mountPath: /dev/dri
      - name: mesa-libs
        mountPath: /mesa-libs
    volumes:
    - name: npu-device
      hostPath:
        path: /dev/accel
    - name: dri-device
      hostPath:
        path: /dev/dri
    - name: mesa-libs
      hostPath:
        path: /run/opengl-driver/lib
  ```

**Option C: Node Affinity + Unprivileged Container** (Middle Ground)
- **Pros**:
  - Doesn't require full privilege escalation
  - Uses `nodeSelector` to target opi01-03 nodes
  - Can work with Pod Security Standards (restricted mode with exceptions)
- **Cons**:
  - Still requires `hostPath` volumes (some security concern)
  - No automatic resource tracking
  - Requires device group permissions (add container user to `render` group)
- **Implementation**:
  - Use `hostPath` for `/dev/accel` and `/dev/dri`
  - Set `securityContext.runAsGroup: 303` (render group GID)
  - Add `nodeSelector: npu.available: "true"` label to opi01-03

**Recommended Approach**:
- **Phase 3.1**: Start with **Option B** (privileged container) for rapid prototyping
- **Phase 3.2**: Move to **Option C** (unprivileged with hostPath) for improved security
- **Phase 3.3** (Optional): Implement **Option A** (device plugin) for production-grade multi-tenant scheduling

**Tasks**:
- [x] Document device access options (this section)
- [x] Choose initial approach (Option B - privileged container with hostPath)
- [x] Test device access from minimal Alpine container
- [x] Verify `/dev/accel/accel0` permissions inside container (mode 0666, accessible)
- [x] Validate Mesa Teflon library loading from host mount

**Status**: ✅ **COMPLETE** (2025-12-11)

**Test Results**:
- Device access validated with Alpine container: `/dev/accel/accel0` accessible
- Mesa Teflon library mounted successfully from `/run/opengl-driver/lib`
- **Critical NixOS Discovery**: Must mount both `/run/opengl-driver/lib` (symlinks) AND `/nix/store` (actual library files)
- Device permissions: `crw-rw-rw-` (mode 0666, nobody:nobody) - accessible to all users

#### 3.2 Build Container Image

**Goal**: Create OCI container image with TensorFlow Lite + Mesa Teflon support.

**Image Requirements**:
- Base: NixOS (for consistency) or Debian/Ubuntu (for wider compatibility)
- Runtime: Python 3.11+ with TensorFlow Lite
- Libraries: Mesa Teflon delegate (from host mount, not in image)
- Model: MobileNetV1 quantized model bundled in image
- Entrypoint: HTTP inference service (Flask/FastAPI)

**Dockerfile Strategy** (NixOS-based):

```dockerfile
# Use nixpkgs-unstable for Python 3.11 + TensorFlow
FROM nixos/nix:latest

# Install runtime dependencies
RUN nix-env -iA nixpkgs.python311 \
    nixpkgs.python311Packages.numpy \
    nixpkgs.python311Packages.pillow \
    nixpkgs.python311Packages.tensorflow-bin \
    nixpkgs.python311Packages.flask

# Copy test script (adapted for HTTP service)
COPY scripts/npu/tflite-npu-test.py /app/inference.py
COPY scripts/npu/inference-server.py /app/server.py

# Download MobileNetV1 model at build time
RUN mkdir -p /app/models && \
    cd /app/models && \
    wget https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz && \
    tar -xzf mobilenet_v1_1.0_224_quant.tgz && \
    rm mobilenet_v1_1.0_224_quant.tgz

# Mesa Teflon will be mounted from host at /mesa-libs
ENV LD_LIBRARY_PATH=/mesa-libs:$LD_LIBRARY_PATH

WORKDIR /app
EXPOSE 8080

CMD ["python3", "server.py"]
```

**Alternative: Debian-based** (smaller, more portable):

```dockerfile
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    numpy \
    pillow \
    tensorflow \
    flask

COPY scripts/npu/inference-server.py /app/server.py

RUN mkdir -p /app/models && \
    cd /app/models && \
    wget https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz && \
    tar -xzf mobilenet_v1_1.0_224_quant.tgz && \
    rm mobilenet_v1_1.0_224_quant.tgz

ENV LD_LIBRARY_PATH=/mesa-libs:$LD_LIBRARY_PATH

WORKDIR /app
EXPOSE 8080

CMD ["python3", "server.py"]
```

**Tasks**:
- [x] Decide on base image (Debian python:3.11-slim selected)
- [x] Create Dockerfile in `kubernetes/base/apps/ml/npu-inference/`
- [x] Write `scripts/npu/inference-server.py` (Flask HTTP wrapper around TFLite inference)
  - `POST /infer` - accepts image, returns classification ✅
  - `GET /health` - health check endpoint ✅
  - `GET /metrics` - Prometheus metrics (inference count, latency) ✅
  - `GET /` - API documentation endpoint ✅
- [x] Build image on opi01 (local testing, no registry push needed)
- [x] Test image locally with NPU device access

**Status**: ✅ **COMPLETE** (2025-12-11)

**Build Details**:
- **Image**: `localhost/npu-inference:latest`
- **Size**: 1.52 GB
- **Base**: python:3.11-slim (Debian Trixie)
- **Runtime**: TensorFlow 2.15.0 with TFLite
- **Model**: MobileNetV1 quantized (4.1MB, bundled in image)
- **Location**: `kubernetes/base/apps/ml/npu-inference/Dockerfile`

**Build Command** (from repository root):
```bash
# Files needed:
# - kubernetes/base/apps/ml/npu-inference/Dockerfile
# - scripts/npu/inference-server.py

podman build -t npu-inference:latest \
  -f kubernetes/base/apps/ml/npu-inference/Dockerfile \
  .
```

**Run Command** (NixOS hosts - requires /nix/store mount):
```bash
podman run -d \
  --name npu-inference \
  --device=/dev/accel/accel0 \
  --device=/dev/dri/renderD180 \
  -v /run/opengl-driver/lib:/mesa-libs:ro \
  -v /nix/store:/nix/store:ro \
  -p 8080:8080 \
  npu-inference:latest
```

**⚠️ NixOS-Specific Requirement**:
Must mount both `/run/opengl-driver/lib` (contains symlinks to Mesa libraries) AND `/nix/store` (contains actual library files that symlinks point to). Without `/nix/store` mount, Teflon delegate fails to load even though symlink exists.

**Test Results** (2025-12-11 on opi01):
- ✅ Teflon delegate loaded successfully
- ✅ Model loaded: MobileNetV1 quantized (224x224x3 uint8 input)
- ✅ All endpoints functional:
  - `GET /health` → `{"status": "healthy", "model_loaded": true}`
  - `GET /metrics` → Prometheus format metrics
  - `POST /infer` → Image classification with timing
  - `GET /` → API documentation

**Test Image Creation and Inference**:

The inference endpoint accepts image files via multipart/form-data. Two types of test images were used:

**1. Random Noise Images (Performance Testing)**

For NPU speed validation, random RGB images were created:

```bash
# Create test image: random 224x224 RGB image (saved as JPEG)
python3 -c "from PIL import Image; import numpy as np; \
  img = Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)); \
  img.save('test.jpg')"
```

**Why these dimensions?**
- **224x224**: MobileNetV1's expected input size
- **3 channels**: RGB color image (not grayscale)
- **uint8**: Quantized model expects integer values 0-255
- **Random data**: Valid for performance testing (actual classification results meaningless)

**2. Real Images (Production Inference)**

To validate the model produces **meaningful classifications**, real images were tested:

```bash
# Download real cat image
curl -o cat.jpg https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/500px-Cat03.jpg

# Run inference
curl -s -X POST -F "image=@cat.jpg" http://localhost:8080/infer | jq .
```

**Real Cat Image Result:**
```json
{
  "predictions": [
    {"class_id": 286, "score": 171.0},  // Egyptian cat ✓
    {"class_id": 283, "score": 45.0},   // tiger cat ✓
    {"class_id": 282, "score": 28.0}    // tabby ✓
  ],
  "inference_time_ms": 16.43
}
```

✅ **Model correctly classifies real objects** - all top 3 predictions are cat breeds!

**Random Noise vs Real Images:**
- **Random noise** → Predicts "apron" (meaningless, no real object present)
- **Real cat photo** → Predicts "Egyptian cat", "tiger cat", "tabby" (correct!)
- **Conclusion**: Service is **production-ready for actual inference workloads**, not just performance testing

**Server-side preprocessing** (`scripts/npu/inference-server.py:90-115`):
1. Accepts any image format (JPEG, PNG, etc.) via HTTP POST
2. Opens image with PIL and converts to RGB if needed
3. Resizes to 224x224 using bilinear interpolation
4. Converts to numpy uint8 array
5. Adds batch dimension: `(224, 224, 3)` → `(1, 224, 224, 3)`
6. Passes to TFLite interpreter for inference

**Sending inference request**:
```bash
# Using test image (random data)
curl -X POST -F "image=@test.jpg" http://localhost:8080/infer

# Using real image (any format, any size - server handles resizing)
curl -X POST -F "image=@cat.png" http://localhost:8080/infer
curl -X POST -F "image=@photo.jpg" http://localhost:8080/infer
```

**Response format**:
```json
{
  "success": true,
  "predictions": [
    {"class_id": 412, "score": 120.0},
    {"class_id": 742, "score": 32.0},
    {"class_id": 736, "score": 23.0},
    {"class_id": 886, "score": 12.0},
    {"class_id": 609, "score": 6.0}
  ],
  "inference_time_ms": 16.32,
  "shape": [1, 1001]
}
```

**Understanding the output**:
- **predictions**: Top 5 class IDs with confidence scores (quantized INT8 values)
- **class_id**: ImageNet class index (0-1000, maps to object categories)
- **score**: Quantized confidence score (not normalized probability)
- **inference_time_ms**: Time for NPU inference only (excludes preprocessing/HTTP)
- **shape**: Output tensor shape (1 batch, 1001 classes including background)

**To get human-readable labels**, map class IDs to ImageNet labels:
```bash
# Download ImageNet label file
wget https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt

# Map class_id 412 to label
sed -n '413p' ImageNetLabels.txt  # Line 413 = class_id 412 (0-indexed)
```

**Performance Results** (10 inference tests with random images):
- **Average inference time**: 14.93ms
- **Range**: 11.88ms - 20.19ms
- **Min**: 11.88ms
- **Max**: 20.19ms
- **First inference**: 20.19ms (slightly slower, expected warmup)
- **Subsequent**: 11.88ms - 16.8ms (consistent NPU performance)

**Performance Comparison**:
- **Bare metal** (Phase 2): 13.66ms average
- **Containerized** (Phase 3): 14.93ms average
- **Overhead**: ~1.3ms (9.3% overhead, acceptable)
- **Conclusion**: ✅ NPU acceleration working correctly in container

#### 3.3 Deploy Example Workload

**Goal**: Deploy NPU inference service to K3s cluster and validate end-to-end.

**Kubernetes Manifests**:

**Deployment** (`kubernetes/base/apps/ml/npu-inference/deployment.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: npu-inference
  namespace: ml
spec:
  replicas: 1  # Start with 1, only one NPU device per node
  selector:
    matchLabels:
      app: npu-inference
  template:
    metadata:
      labels:
        app: npu-inference
    spec:
      nodeSelector:
        kubernetes.io/hostname: opi01  # Target specific controller node
      containers:
      - name: inference
        image: ghcr.io/yourusername/npu-inference:latest
        ports:
        - containerPort: 8080
          name: http
        securityContext:
          privileged: true  # Phase 3.1: Use privileged for initial testing
        volumeMounts:
        - name: npu-device
          mountPath: /dev/accel
        - name: dri-device
          mountPath: /dev/dri
        - name: mesa-libs
          mountPath: /mesa-libs
          readOnly: true
        - name: nix-store
          mountPath: /nix/store
          readOnly: true
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: npu-device
        hostPath:
          path: /dev/accel
      - name: dri-device
        hostPath:
          path: /dev/dri
      - name: mesa-libs
        hostPath:
          path: /run/opengl-driver/lib
      - name: nix-store  # Required for NixOS: symlink targets
        hostPath:
          path: /nix/store
```

**Service** (`kubernetes/base/apps/ml/npu-inference/service.yaml`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: npu-inference
  namespace: ml
spec:
  selector:
    app: npu-inference
  ports:
  - name: http
    port: 80
    targetPort: 8080
  type: ClusterIP
```

**Ingress** (`kubernetes/base/apps/ml/npu-inference/ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: npu-inference
  namespace: ml
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - npu-inference.internal
    secretName: npu-inference-tls
  rules:
  - host: npu-inference.internal
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: npu-inference
            port:
              number: 80
```

**Tasks**:
- [ ] Create namespace: `kubectl create namespace ml`
- [ ] Create Kubernetes manifests in `kubernetes/base/apps/ml/npu-inference/`
- [ ] Create ArgoCD Application manifest
- [ ] Deploy via ArgoCD or Flux
- [ ] Verify pod starts and NPU device is accessible:
  ```bash
  kubectl exec -n ml deployment/npu-inference -- ls -la /dev/accel/accel0
  kubectl exec -n ml deployment/npu-inference -- ls -la /dev/dri/renderD180
  ```
- [ ] Check logs for Teflon delegate loading
- [ ] Test inference endpoint:
  ```bash
  # Port-forward for testing
  kubectl port-forward -n ml svc/npu-inference 8080:80

  # Send test image
  curl -X POST -F "image=@test.jpg" http://localhost:8080/infer
  ```
- [ ] Validate NPU is being used (check inference latency ~13ms)
- [ ] Test via Ingress: `curl -X POST -F "image=@test.jpg" https://npu-inference.internal/infer`

#### 3.4 Validation & Performance Testing

**Goal**: Confirm NPU acceleration is working in Kubernetes environment.

**Test Cases**:
1. **Basic Functionality**:
   - [ ] Pod starts successfully and stays healthy
   - [ ] `/health` endpoint returns 200 OK
   - [ ] Single inference request completes successfully
   - [ ] Response contains valid classification results

2. **NPU Acceleration Verification**:
   - [ ] Inference latency is <50ms (ideally ~13-16ms like bare metal)
   - [ ] Check container logs for Teflon delegate load messages
   - [ ] Monitor NPU device logs: `kubectl exec -n ml deployment/npu-inference -- dmesg | grep rocket`
   - [ ] Compare performance: NPU-enabled vs CPU-only (should be 10-100x faster)

3. **Load Testing**:
   - [ ] Send 100 concurrent requests (simulate load)
   - [ ] Measure throughput (requests/second)
   - [ ] Verify no performance degradation over time
   - [ ] Check for memory leaks or resource issues

4. **Multi-Pod Scheduling** (if using device plugin):
   - [ ] Deploy 2 replicas, verify only 1 schedules (single NPU)
   - [ ] Verify second pod stays pending with "Insufficient npu.rockchip.com/rk3588" event
   - [ ] Scale to 3 replicas across opi01-03 (if deploying to all controllers)

**Metrics to Collect**:
- Average inference latency (ms)
- Requests per second (throughput)
- Memory usage (container vs host)
- CPU usage (should be minimal if NPU is working)
- NPU utilization (if available via driver metrics)

**Tasks**:
- [ ] Run basic functionality tests
- [ ] Compare bare-metal vs containerized NPU performance
- [ ] Run load test with 100 concurrent requests
- [ ] Document performance results
- [ ] Take screenshots/logs of successful NPU inference in K8s

#### 3.5 Optional Enhancements

**Advanced Features** (lower priority):

1. **Kubernetes Device Plugin**:
   - [ ] Implement custom device plugin for RK3588 NPU
   - [ ] Deploy as DaemonSet on opi01-03 nodes
   - [ ] Update deployments to use `resources.limits.npu.rockchip.com/rk3588: 1`
   - [ ] Test multi-tenant NPU scheduling

2. **Model Serving Framework**:
   - [ ] Integrate with KServe or Seldon Core
   - [ ] Implement model versioning and A/B testing
   - [ ] Add model warmup and preloading

3. **Monitoring & Observability**:
   - [ ] Add Prometheus metrics exporter
   - [ ] Create Grafana dashboard for NPU workloads
   - [ ] Track inference latency, throughput, error rates
   - [ ] Alert on NPU device failures or performance degradation

4. **Additional Models**:
   - [ ] Test SSDLite MobileDet (object detection)
   - [ ] Test MobileNetV2, EfficientNet-Lite
   - [ ] Create model zoo with multiple quantized models

5. **CI/CD Integration**:
   - [ ] Automate container image builds (GitHub Actions)
   - [ ] Push to ghcr.io registry
   - [ ] Auto-deploy via ArgoCD on image update

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
- [x] TFLite runtime can load Teflon and run inference on NPU ✅
- [x] MobileNetV1 inference achieves <50ms latency (bare metal: 13.66ms, container: 14.93ms) ✅
- [x] Container image with TFLite + Teflon built and tested ✅
- [x] NPU acceleration working in containers with acceptable overhead (<10%) ✅
- [ ] Object detection achieves ≥30 FPS (optional)
- [ ] Kubernetes pods can access NPU hardware
- [ ] Documentation enables others to build TFLite NPU workloads
- [ ] Example workload demonstrates realistic usage

## Timeline

No specific deadline. Phases can be pursued at own pace:
- Phase 1: Kernel integration (✅ COMPLETE - 2025-12-10)
- Phase 2: TFLite + Teflon testing (✅ COMPLETE - 2025-12-11)
- Phase 3: K8s integration (🚧 IN PROGRESS - 2025-12-11)
  - Phase 3.1: Device access validation (✅ COMPLETE - 2025-12-11)
  - Phase 3.2: Container image build (✅ COMPLETE - 2025-12-11)
  - Phase 3.3: K8s deployment (⏳ PENDING)
  - Phase 3.4: Validation & testing (⏳ PENDING)
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

1. **Phase 2 Complete** ✅:
   - ~~Install tflite-runtime on opi01~~ ✅
   - ~~Download MobileNetV1 quantized model~~ ✅
   - ~~Run basic inference test with Teflon delegate~~ ✅
   - ~~Verify NPU acceleration is working~~ ✅
   - ~~Benchmark performance~~ ✅ (13.66ms avg)

2. **Phase 3: Kubernetes Integration** (Current):

   **Step 3.1: Validate Device Access** ✅ COMPLETE
   - ~~Choose Option B (privileged container) for initial testing~~ ✅
   - ~~Test NPU device access from a minimal container on opi01~~ ✅
   - ~~Verify Mesa Teflon loads from host mount~~ ✅
   - **Key Finding**: NixOS requires both `/run/opengl-driver/lib` AND `/nix/store` mounts

   **Step 3.2: Build Container Image** ✅ COMPLETE
   - ~~Decide on base image~~ ✅ (Debian python:3.11-slim)
   - ~~Write `scripts/npu/inference-server.py` (Flask HTTP service)~~ ✅
   - ~~Create `kubernetes/base/apps/ml/npu-inference/Dockerfile`~~ ✅
   - ~~Build and test locally with Podman~~ ✅
   - **Performance**: 14.93ms avg (9.3% overhead vs bare metal)

   **Step 3.3: Deploy to Kubernetes** (Next)
   - [ ] Create namespace and manifests
   - [ ] Deploy via ArgoCD (or kubectl for testing)
   - [ ] Test HTTP inference endpoint via Ingress
   - [ ] Validate NPU performance in K8s environment

   **Step 3.4: Document Results**
   - [x] Capture Phase 3.1 & 3.2 performance metrics ✅
   - [x] Document NixOS-specific requirements ✅
   - [ ] Take screenshots/logs of K8s deployment
   - [ ] Create usage guide for running NPU workloads

3. **Optional Enhancements** (After Phase 3 core complete):
   - Test object detection with SSDLite MobileDet
   - Implement Kubernetes device plugin (Option A)
   - Add Prometheus metrics and Grafana dashboard
   - Test multi-core NPU performance
   - Benchmark additional models (MobileNetV2, EfficientNet-Lite)

## Notes

- This is exploratory; no immediate production use cases
- NPU support is different from Ollama (LLM inference) - focused on computer vision and general ML
- Mainline approach ensures long-term support and community contributions
- Mesa Teflon is actively developed; expect operation coverage to expand
- Performance optimization is ongoing; may not yet match vendor driver in all scenarios
- For models requiring unsupported operations, CPU fallback occurs automatically
