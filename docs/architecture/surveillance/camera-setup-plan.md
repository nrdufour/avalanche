# Surveillance Camera Setup Plan

## Overview

This document outlines the complete plan for deploying and integrating a Loryta IPC-T5442TM-AS 4MP Starlight+ surveillance camera with Frigate NVR on the Avalanche Kubernetes cluster. The goal is to establish a local, privacy-focused video surveillance system with AI-powered object detection using existing RK3588 NPU hardware acceleration.

## Context

- **Camera**: Loryta IPC-T5442TM-AS 3.6mm (Dahua OEM, purchased 2022)
- **NVR Software**: Frigate (open-source, privacy-first network video recorder)
- **Deployment**: Kubernetes cluster (K3s on opi01-03 + raccoon00-05)
- **Object Detection**: Frigate with RK3588 NPU acceleration (via RKNN models)
- **Primary Use Case**: Wildlife/animal detection from garden surveillance
- **Related Infrastructure**: Existing NPU integration (see `rknn-npu-integration-plan.md`)

## Hardware Specifications

### Camera: Loryta IPC-T5442TM-AS

**Full Model**: IPC-T5442TM-AS 3.6mm Fixed Lens 4MP Starlight+ WDR IR Turret AI IP Camera

**Image Sensor:**
- 1/1.8" 4 Megapixel progressive scan CMOS
- Effective pixels: 2688(H) × 1520(V)
- Maximum resolution: 2688×1520 @ 25/30fps

**Lens:**
- Fixed focal length: 3.6mm
- Maximum aperture: F1.6
- Angle of view: H:89°, V:48°, D:107°

**Low Light Performance:**
- Minimum illumination: 0.0016Lux/F1.6 (Color, 1/3s, 30IRE)
- Starlight+ technology for exceptional night vision
- Color night vision: 0.015Lux/F1.6 (Color, 1/30s, 30IRE)
- IR mode: 0Lux/F1.6 (IR on)

**Infrared:**
- IR LEDs: 2x high-power IR illuminators
- IR distance: Up to 51m (167ft)
- IR control: Auto/Manual
- Smart IR: Prevents overexposure at close range

**Video Encoding:**
- Compression: H.265 & H.264 (triple-stream encoding)
- Main stream: Up to 2688×1520 @ 25/30fps
- Sub stream: Up to 704×576 @ 25/30fps
- Third stream: Configurable

**Advanced Features:**
- WDR: 120dB Wide Dynamic Range
- Day/Night: ICR (Infrared Cut filter Removal)
- 3D DNR: Digital Noise Reduction
- BLC: Backlight Compensation
- HLC: Highlight Compensation
- Defog

**AI Features (On-Camera):**
- Perimeter Protection: Tripwire, Intrusion detection
- Human and Vehicle classification
- People counting
- Line crossing detection
- Region people counting

**Network:**
- Ethernet: 10/100Base-T, RJ45
- Protocol: ONVIF, RTSP, HTTP, TCP/IP, DHCP, DNS, etc.
- Power: IEEE 802.3af PoE (Power over Ethernet)
- Power consumption: Max 6.5W

**Physical:**
- Housing: IP67 weatherproof rating
- Operating temperature: -30°C to +60°C (-22°F to +140°F)
- Mounting: Turret/eyeball design with junction box mount

**Built-in Audio:**
- Microphone: Built-in
- Audio compression: G.711a, G.711Mu, G.726, AAC

**Storage:**
- RAM: 512MB
- Flash: 128MB
- Supports edge recording to SD card (not included)

### NPU Hardware (Existing)

**Available NPU Resources:**
- 3× Orange Pi 5 Plus (opi01-03) with RK3588 SoC
- Each RK3588 has 3 NPU cores (6 TOPS combined)
- Total: 9 NPU cores available across cluster
- `/dev/accel/accel0` device exposed on each node
- Mesa 25.3+ with rocket driver (mainline kernel)

**NPU Performance for Object Detection:**
- YOLO-NAS S model: 25-30ms inference (RK3588, 3 cores)
- MobileNetV1: 13-16ms inference (proven working)
- SSDLite MobileDet: 30 FPS capable (single core)

## Network Configuration

### Camera Default Settings

**Default IP Address:** `192.168.1.108`

**Default Credentials:**
- Username: `admin`
- Password: `admin` (⚠️ **MUST be changed immediately**)

**Default Ports:**
- HTTP: 80
- RTSP: 554
- ONVIF: 80

### Initial Network Setup

**Option A: Use Default Static IP (Quick Test)**
1. Connect camera to network via PoE switch
2. Temporarily configure workstation/laptop with static IP: `192.168.1.100/24`
3. Access camera web interface: `http://192.168.1.108`
4. Login with default credentials
5. Change admin password immediately
6. Configure network settings for production

**Option B: DHCP Discovery (Recommended)**
1. Connect camera to network via PoE switch
2. Use network scanner to find camera:
   ```bash
   nmap -sn 10.1.0.0/24  # Scan local network
   # Or use Dahua ConfigTool / ONVIF Device Manager
   ```
3. Access camera web interface via discovered IP
4. Change default password
5. Configure static IP or DHCP reservation

### Production Network Configuration

**Recommended Network Assignment:**
- **VLAN**: Create dedicated camera VLAN (optional but recommended for security)
- **IP Assignment**: Static IP or DHCP reservation via router
- **Suggested IP**: `10.1.0.50` (or next available in your network)
- **Subnet**: Match existing infrastructure (e.g., `10.1.0.0/24`)
- **Gateway**: Router IP (e.g., `10.1.0.1`)
- **DNS**: Local DNS server or `1.1.1.1`, `8.8.8.8`

**Hostname:** `camera01.internal` (add to Tailscale DNS or local DNS)

## RTSP Stream Configuration

### RTSP URL Format

Dahua cameras use the following RTSP URL structure:

```
rtsp://<username>:<password>@<ip_address>:<port>/cam/realmonitor?channel=<channel>&subtype=<stream_type>
```

**Parameters:**
- `username`: Camera login username (e.g., `admin`)
- `password`: Camera password (**use strong password, not default**)
- `ip_address`: Camera IP address (e.g., `10.1.0.50`)
- `port`: RTSP port (default: `554`)
- `channel`: Camera channel number (always `1` for single camera)
- `subtype`: Stream type
  - `0` = Main stream (high quality, high bandwidth)
  - `1` = Sub stream (medium quality)
  - `2` = Third stream (low quality, low bandwidth)

### Example RTSP URLs

**Main Stream (High Quality - Recording):**
```
rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0
```
- Resolution: 2688×1520 (4MP)
- Bitrate: 4-8 Mbps (H.265)
- Use for: High-quality recording, playback

**Sub Stream (Medium Quality - Live View):**
```
rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=1
```
- Resolution: 704×576 or 1280×720
- Bitrate: 512-2048 Kbps
- Use for: Live viewing, lower bandwidth

**Third Stream (Low Quality - Object Detection):**
```
rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=2
```
- Resolution: Configurable (recommend 640×480 for detection)
- Bitrate: 256-512 Kbps
- Use for: Object detection input (Frigate)

### Frigate Stream Configuration

Frigate uses multiple streams for different purposes:

1. **Detect Stream** (Low quality, low latency):
   - RTSP subtype 2 (third stream)
   - Resolution: 640×480 or 704×576
   - Purpose: Object detection input (lower res = faster inference)

2. **Record Stream** (High quality):
   - RTSP subtype 0 (main stream)
   - Resolution: 2688×1520 (full 4MP)
   - Purpose: Recording events and continuous recording

### Testing RTSP Streams

**Using VLC Media Player:**
```bash
# Open VLC → Media → Open Network Stream
# Enter URL:
rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0
```

**Using ffplay (command line):**
```bash
# Test main stream
ffplay -rtsp_transport tcp "rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0"

# Test sub stream (detection)
ffplay -rtsp_transport tcp "rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=2"
```

**Using ffmpeg (analyze stream):**
```bash
# Get stream information
ffprobe -rtsp_transport tcp "rtsp://admin:your_password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0"
```

## Frigate NVR Overview

### What is Frigate?

[Frigate](https://frigate.video) is an open-source network video recorder (NVR) designed for real-time AI object detection. It prioritizes privacy by performing all processing locally on your own hardware.

**Key Features:**
- **Local Processing**: All video processing happens locally, camera feeds never leave your network
- **Real-time Object Detection**: AI-powered detection of people, vehicles, animals, packages
- **High Performance**: Capable of 100+ object detections per second with proper hardware
- **Zone-Based Tracking**: Monitor specific areas (e.g., driveway, front steps, garden)
- **Smart Alerts**: Reduces false positives by analyzing actual objects, not just motion
- **Home Automation Integration**: Works with Home Assistant, OpenHab, NodeRed, MQTT
- **Hardware Acceleration**: Supports Coral TPU, Rockchip NPU, OpenVINO, TensorRT
- **Web UI**: Modern web interface for live view, playback, configuration
- **Mobile Apps**: iOS and Android apps for remote access

### Frigate+ (Optional Premium Service)

Frigate+ provides enhanced object detection models trained on real security camera footage:
- **Standard Models** (Free): People, vehicles, common objects
- **Frigate+ Models** (Premium): Packages, delivery logos (UPS, FedEx, Amazon), wildlife (foxes, raccoons, squirrels, deer), faces, license plates (v0.16+)

**Note**: Standard free models are sufficient for wildlife/animal detection use case.

### Supported Detectors

Frigate supports multiple hardware acceleration backends:

| Detector | Hardware | Performance | Power | Status |
|----------|----------|-------------|-------|--------|
| **Coral TPU** | Google Coral (USB/M.2) | ~15ms inference | Very Low (2W) | Supported (legacy) |
| **Rockchip NPU** | RK3588/RK3588S (Orange Pi 5, Rock 5) | ~25-30ms inference | Low (SBC integrated) | ✅ **Recommended for Avalanche** |
| **OpenVINO** | Intel iGPU/CPU | Varies | Medium | Supported |
| **TensorRT** | NVIDIA GPU | Very Fast | High | Supported |
| **CPU** | Any CPU (fallback) | >60ms inference | Medium-High | Default (slow) |

**Important**: Multiple detector types cannot be mixed for object detection (e.g., cannot use Coral + RKNN simultaneously).

### Why Frigate is Ideal for Avalanche

1. **NPU Integration**: Can leverage existing RK3588 NPU infrastructure
2. **Kubernetes Native**: Official Helm chart, designed for K8s deployment
3. **Privacy First**: All processing local, no cloud dependencies
4. **Open Source**: MIT licensed, active development
5. **Low Power**: Efficient inference on NPU (vs. GPU-based solutions)
6. **Extensible**: MQTT integration, REST API, webhooks

## Deployment Strategy

### Phase 1: Camera Physical Setup

**Objective**: Mount camera, establish network connectivity, verify basic functionality.

**Status**: 🟡 **PARTIAL** (2026-02-01) - Network setup complete, outdoor mounting pending

#### Tasks
- [ ] 1.1 Physical Installation (PENDING - outdoor mounting not done yet)
  - [ ] Choose camera mounting location (outdoor, garden view)
  - [ ] Mount camera bracket to wall/surface
  - [ ] Aim camera at desired coverage area
  - [ ] Verify field of view covers intended area
  - [ ] Ensure camera is level and stable

- [x] 1.2 Power and Network
  - [x] Connect camera to PoE switch via ethernet cable
  - [x] Verify camera powers on (status LED)
  - [x] Confirm network link (PoE switch port LED)
  - [ ] Document cable route and switch port number (pending permanent install)

- [x] 1.3 Initial Discovery
  - [x] Scan network for camera IP address
    ```bash
    # Used nmap scan on 10.0.0.0/24 network
    nmap -sn 10.0.0.0/24
    ```
  - [x] Access camera web interface via discovered IP
  - [x] Verify camera responds to HTTP requests

#### Notes
- Camera currently set up indoors for testing/validation
- Outdoor permanent mounting to be done later
- Camera initially obtained IP 10.0.0.134 via DHCP after factory reset
- Factory reset was required (default 192.168.1.108 not reachable on network)
- Reset procedure: hold reset button under SD card hatch for 10+ seconds

#### Expected Outcome
- Camera physically mounted and aimed - ⏳ pending outdoor install
- Camera powered via PoE ✅
- Camera accessible on network ✅
- Default IP address identified ✅

### Phase 2: Camera Configuration

**Objective**: Secure camera, configure network settings, optimize video streams for Frigate.

**Status**: ✅ **COMPLETED** (2026-02-01)

#### Tasks
- [x] 2.1 Security Hardening
  - [x] Change default admin password to strong password
    - Password stored in Bitwarden "Home Automation" item as `FRIGATE_RTSP_PASSWORD`
    - Password contains special characters (`$`, `[`, `]`) - requires URL encoding for manual RTSP testing
  - [ ] Disable UPnP (security risk) - *skipped for now*
  - [ ] Disable unnecessary services (P2P, cloud features) - *skipped for now*
  - [ ] Enable HTTPS if supported (for web UI access) - *not available*
  - [ ] Create separate user account for Frigate RTSP access (read-only) - *using admin account*

- [x] 2.2 Network Configuration
  - [x] Set static IP address: `10.0.0.50`
  - [x] Configure gateway and DNS
  - [x] Verify network connectivity (ping test)
  - [ ] Add camera to Tailscale DNS or local DNS as `camera01.internal` - *not done yet*

- [x] 2.3 Video Stream Configuration
  - [x] Configure **Main Stream** (Recording):
    - Resolution: 2688×1520 (4MP, native)
    - Used for recording in Frigate (subtype=0)

  - [x] Configure **Sub Stream** (Detection):
    - Resolution: 704×576
    - Frame rate: 5 FPS
    - Used for detection in Frigate (subtype=1)

- [x] 2.4 Camera Settings Optimization
  - [x] Default camera settings working well for garden view
  - [x] IR mode: Auto (switches to IR at night)

- [x] 2.5 RTSP Stream Testing
  - [x] Test main stream with ffplay
  - [x] Test sub stream (low res)
  - [x] Verify streams stable
  - [x] Document final RTSP URLs for Frigate config

#### RTSP URLs (Actual)
```
# Main stream (recording) - subtype=0
rtsp://admin:{FRIGATE_RTSP_PASSWORD}@10.0.0.50:554/cam/realmonitor?channel=1&subtype=0

# Sub stream (detection) - subtype=1
rtsp://admin:{FRIGATE_RTSP_PASSWORD}@10.0.0.50:554/cam/realmonitor?channel=1&subtype=1
```

#### Notes
- Used subtype=1 (sub stream) for detection instead of subtype=2 (third stream)
- Password with special characters requires URL encoding for manual testing:
  ```bash
  ffplay -rtsp_transport tcp "rtsp://admin:%24%5Bxj72PVQB%5D@10.0.0.50:554/cam/realmonitor?channel=1&subtype=0"
  ```
- Frigate handles URL encoding automatically when using environment variable substitution

#### Expected Outcome
- Camera secured with strong password ✅
- Static IP assigned ✅
- RTSP streams optimized for Frigate ✅
- All streams tested and verified stable ✅

### Phase 3: Frigate Deployment Planning

**Objective**: Design Frigate Kubernetes deployment architecture.

#### 3.1 Architecture Decisions

**Deployment Method: Kubernetes Helm Chart** ✅

Official Frigate Helm chart available:
- Repository: `https://blakeblackshear.github.io/blakeshome-charts/`
- Chart: `blakeblackshear/frigate`
- Latest version: 7.8.0+

**Storage Requirements:**

1. **Configuration**: ConfigMap (small, <10KB)
2. **Database**: PVC for Frigate SQLite database
   - Size: 10GB (stores metadata, not video)
   - Storage class: `local-path` or `longhorn`
3. **Recordings**: PVC for video recordings
   - Size: 100GB - 1TB (depends on retention policy)
   - Storage class: `longhorn` (distributed, replicated)
4. **Clips**: Separate PVC or same as recordings
   - Size: 20GB - 100GB

**Node Selection:**

Frigate pod should run on node with:
- ✅ RK3588 NPU (opi01-03)
- ❌ NOT on raccoon00-05 (RPi4 has no suitable NPU)

**Recommended**: Use node affinity to schedule on `opi01` (K3s controller)

**Resource Allocation:**

```yaml
resources:
  requests:
    memory: 1Gi
    cpu: 500m
  limits:
    memory: 4Gi
    cpu: 2000m
```

**NPU Device Access:**

Similar to existing NPU inference service, Frigate needs:
- `/dev/accel/accel0` (NPU device)
- `/dev/dri/renderD180` (symlink)
- `/run/opengl-driver/lib` (Mesa libraries)
- `/nix/store` (library symlink targets, NixOS specific)

**Network:**

- Service type: `ClusterIP`
- Ingress: HTTPS via nginx ingress controller
- Hostname: `frigate.internal`
- Certificate: step-ca ACME (existing setup)

#### 3.2 Detector Configuration

⚠️ **CRITICAL INCOMPATIBILITY**: Frigate's RKNN detector **WILL NOT WORK** on Avalanche infrastructure.

**Why RKNN Doesn't Work:**
- Frigate RKNN detector requires vendor kernel with `rknpu` driver
- Avalanche uses **mainline kernel** with `rocket` driver (by design)
- RKNN Runtime (`librknnrt.so`) is incompatible with mainline stack
- Switching to vendor kernel breaks entire mainline architecture

**Deployment Strategy: Two-Phase Approach**

**Phase 1 (Initial Deployment): CPU Detector** ✅

Deploy Frigate with CPU-only object detection:

```yaml
detectors:
  cpu:
    type: cpu
    num_threads: 4  # Adjust based on available CPU cores
```

**Performance Expectations:**
- Inference time: ~60-100ms (vs ~25-30ms with NPU)
- CPU usage: Moderate to high (one core per camera)
- Sufficient for single camera deployment
- Validates entire Frigate setup (camera, recording, zones)

**Benefits:**
- Works immediately, no NPU complications
- Proves Frigate deployment and camera integration
- Establishes baseline for comparison
- Can be upgraded to NPU later without redeployment

**Phase 2 (Future): Custom YOLO-TFLite Detection Service** 🎯

Build custom object detection HTTP service using mainline NPU stack:

**Architecture:**
```
Camera → Frigate (HTTP detector) → YOLO-TFLite Service (NPU) → Bounding Boxes → Frigate
```

**Custom Service Requirements:**
- **NPU Stack**: Mesa Teflon (TensorFlow Lite delegate) - mainline compatible
- **Model**: YOLO model converted to TFLite format (`.tflite`)
- **API**: REST endpoint accepting images, returning bounding boxes
- **Device**: `/dev/accel/accel0` (same as existing npu-inference)
- **Base**: Similar to existing `npu-inference` service architecture

**Frigate HTTP Detector Configuration:**
```yaml
detectors:
  yolo_tflite:
    type: http
    url: http://yolo-detector.ml.svc.cluster.local:8080/detect
```

**Expected Performance:**
- Inference: ~25-40ms (YOLO on RK3588 NPU via TFLite)
- Compatible with mainline kernel ✅
- No vendor dependencies ✅
- Reuses existing NPU infrastructure ✅

**Development Plan** (Phase 2 - see Phase 7 below):
1. Research YOLO model conversion to TFLite
2. Test YOLO TFLite models on existing npu-inference service
3. Implement object detection endpoint (vs classification)
4. Parse bounding boxes and return in Frigate-compatible format
5. Deploy as separate K8s service
6. Configure Frigate to use HTTP detector

**Recommended**: Start with **Phase 1 (CPU detector)** to validate Frigate deployment. Implement **Phase 2 (custom service)** after Frigate is stable and proven.

#### 3.3 Camera Configuration

**Frigate Camera Config** (`config.yml`):
```yaml
cameras:
  camera01:  # Camera name (unique identifier)
    enabled: True
    ffmpeg:
      inputs:
        # High-quality recording stream
        - path: rtsp://admin:{FRIGATE_CAMERA_PASSWORD}@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0
          roles:
            - record

        # Low-quality detection stream
        - path: rtsp://admin:{FRIGATE_CAMERA_PASSWORD}@10.1.0.50:554/cam/realmonitor?channel=1&subtype=2
          roles:
            - detect

    detect:
      enabled: True
      width: 640
      height: 480
      fps: 5  # Detection FPS (low = less CPU/NPU usage)

    record:
      enabled: True
      retain:
        days: 7  # Keep recordings for 7 days
        mode: motion  # Only record when motion/objects detected
      events:
        retain:
          default: 14  # Keep event clips for 14 days
          mode: active_objects

    snapshots:
      enabled: True
      retain:
        default: 14  # Keep snapshots for 14 days

    objects:
      track:
        - person
        - cat
        - dog
        - bird
        - wildlife  # If Frigate+ model used
      filters:
        person:
          min_area: 5000  # Minimum pixel area to trigger (tune this)
          threshold: 0.7  # Confidence threshold (0-1)
        cat:
          min_area: 2000
          threshold: 0.6
        dog:
          min_area: 3000
          threshold: 0.6
```

**Password Management:**

Store camera password in Kubernetes Secret (SOPS encrypted):
```yaml
# secrets/frigate/camera-credentials.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: frigate-camera-credentials
  namespace: frigate
type: Opaque
stringData:
  FRIGATE_CAMERA_PASSWORD: "your_strong_password_here"
```

Inject into Frigate config using environment variable substitution.

#### 3.4 Optional Features

**MQTT Integration** (for Home Assistant):
```yaml
mqtt:
  enabled: true
  host: mosquitto.home-automation.svc.cluster.local
  port: 1883
  topic_prefix: frigate
  user: frigate
  password: "{FRIGATE_MQTT_PASSWORD}"
```

**Zones** (monitor specific areas):
```yaml
cameras:
  camera01:
    zones:
      garden:
        coordinates: 100,100,500,100,500,400,100,400  # x,y points
        objects:
          - cat
          - dog
          - bird
      driveway:
        coordinates: 600,100,1200,100,1200,400,600,400
        objects:
          - person
          - car
```

**Notifications** (webhook to Discord/Slack):
```yaml
# Via external notification service or Home Assistant automation
```

#### Expected Outcome
- Frigate architecture designed
- Storage requirements calculated
- Detector strategy defined (RKNN primary, CPU fallback)
- Camera configuration drafted
- Secret management planned

### Phase 4: Frigate Kubernetes Deployment

**Objective**: Deploy Frigate to Kubernetes cluster.

**Status**: ✅ **COMPLETED** (2026-02-01)

#### Tasks
- [x] 4.1 Preparation
  - [x] Namespace: `home-automation` (shared with other home automation apps)
  - [x] Create External Secret for camera password
    - Stored in Bitwarden "Home Automation" item (UUID: ec4485d9-4570-4475-aeb8-4053bd864e4b)
    - Property: `FRIGATE_RTSP_PASSWORD`
  - [x] Create PVCs for storage
    - `frigate-config` (10Gi) - Longhorn
    - `frigate-media` (100Gi) - Longhorn

- [x] 4.2 Kubernetes Manifests (not Helm - raw manifests)
  - [x] Created deployment.yaml
    - Image: `ghcr.io/blakeblackshear/frigate:0.16.4`
    - CPU detector (4 threads)
    - `hostNetwork: true` (required to reach camera on 10.0.0.x)
    - Node selector: `opi.feature.node.kubernetes.io/5plus: "true"` (Orange Pi 5 Plus)
  - [x] Created service.yaml (port 8971 - authenticated)
  - [x] Created ingress.yaml
    - Host: `frigate.internal`
    - TLS via `ca-server-cluster-issuer`
    - `backend-protocol: HTTPS` (port 8971 serves HTTPS)
    - Homepage annotations for auto-discovery
  - [x] Created configmap.yaml (Frigate config)
  - [x] Created pvc.yaml (config + media volumes)
  - [x] Created frigate-es.yaml (External Secret)
  - [x] Created kustomization.yaml

- [x] 4.3 ArgoCD Application
  - [x] Created `kubernetes/base/apps/home-automation/frigate-app.yaml`
  - [x] Added to `kubernetes/base/apps/home-automation/kustomization.yaml`

- [x] 4.4 Deploy Frigate
  - [x] Committed all manifests to Git
  - [x] Pushed to Forgejo
  - [x] ArgoCD synced successfully
  - [x] Pod running on Orange Pi 5 Plus node

- [x] 4.5 Configuration Fixes Applied
  - [x] Fixed `record.events` deprecation (removed in Frigate 0.16.x)
  - [x] Fixed password encoding (store raw password, not URL-encoded)
  - [x] Added `hostNetwork: true` (pod network couldn't reach camera)
  - [x] Fixed ingress class (`nginx` not `nginx-internal`)
  - [x] Fixed cluster issuer (`ca-server-cluster-issuer`)
  - [x] Fixed authentication (use port 8971, not 5000)
  - [x] Added `backend-protocol: HTTPS` annotation
  - [x] Added node selector for Orange Pi 5 Plus

#### Deployment Files Created
```
kubernetes/base/apps/home-automation/frigate/
├── deployment.yaml      # Frigate deployment with CPU detector
├── service.yaml         # ClusterIP service (port 8971)
├── ingress.yaml         # Ingress with TLS and homepage annotations
├── pvc.yaml             # PVCs for config (10Gi) and media (100Gi)
├── configmap.yaml       # Frigate configuration
├── frigate-es.yaml      # External Secret for RTSP password
└── kustomization.yaml   # Kustomize config

kubernetes/base/apps/home-automation/frigate-app.yaml  # ArgoCD Application
```

#### Key Configuration Details
- **Port 8971**: Authenticated Frigate UI (HTTPS)
- **Port 5000**: Unauthenticated internal API (used for health probes only)
- **hostNetwork**: Required because K8s pod network (10.42.x.x) cannot reach camera (10.0.0.x)
- **Node selector**: Runs on Orange Pi 5 Plus for better ffmpeg performance

#### Expected Outcome
- Frigate pod running on Orange Pi 5 Plus ✅
- Web UI accessible at `https://frigate.internal` ✅
- Authentication required (port 8971) ✅
- Camera streams working ✅

### Phase 5: Camera Integration and Testing

**Objective**: Connect camera to Frigate, verify object detection, tune settings.

**Status**: ✅ **COMPLETED** (2026-02-01)

#### Tasks
- [x] 5.1 Add Camera to Frigate
  - [x] Camera configured in ConfigMap as "garden"
  - [x] Frigate pod started successfully
  - [x] Camera appears in Frigate UI
  - [x] Live view stream works

- [x] 5.2 RTSP Stream Verification
  - [x] Detect stream (704×576, 5 FPS) displays correctly
  - [x] Record stream (2688×1520) displays correctly
  - [x] No stream errors in logs
  - [x] CPU/memory usage acceptable

- [x] 5.3 Object Detection Testing
  - [x] Object detection working with CPU detector
  - [x] Detections appear in Frigate UI
  - [x] Snapshots saved correctly

- [ ] 5.4 NPU Performance Verification - **SKIPPED** (using CPU detector)
  - Using CPU detector per Phase 1 deployment strategy
  - NPU acceleration planned for Phase 7 (future)

- [ ] 5.5 Configuration Tuning (partial)
  - [x] Detection FPS: 5 FPS
  - [x] Object filters configured for person, cat, dog, bird
  - [ ] Zones not yet configured (pending outdoor install)
  - [ ] Motion masks not yet configured (pending outdoor install)
  - [x] Recording retention: 7 days (motion mode)
  - [x] Snapshot retention: 14 days

- [ ] 5.6 Notifications Setup - **NOT DONE**
  - MQTT disabled for now
  - Can be configured later with Home Assistant integration

#### Frigate Configuration Summary
```yaml
cameras:
  garden:
    detect:
      width: 704
      height: 576
      fps: 5
    record:
      retain:
        days: 7
        mode: motion
    objects:
      track: [person, cat, dog, bird]
```

#### Expected Outcome
- Camera integrated with Frigate ✅
- Object detection working with CPU detector ✅
- Events and snapshots saved correctly ✅
- Notifications configured - ⏳ deferred

### Phase 6: Production Readiness

**Objective**: Harden deployment, implement monitoring, document operations.

**Note**: This phase completes Frigate with CPU detector. Phase 7 (NPU acceleration) is optional future enhancement.

#### Tasks
- [ ] 6.1 Backup and Recovery
  - [ ] Configure Frigate database backups
    - Daily backup of SQLite database to S3 (Garage)
    - Retention: 30 days
  - [ ] Document database restore procedure
  - [ ] Test backup and restore process

- [ ] 6.2 Monitoring and Alerting
  - [ ] Add Prometheus ServiceMonitor for Frigate
  - [ ] Create Grafana dashboard:
    - Camera uptime
    - Detection count (per object type)
    - Detector inference time
    - CPU/memory usage
    - Storage usage (recordings)
  - [ ] Set up alerts:
    - Camera offline (no frames for 5 minutes)
    - Detector degraded (inference >50ms)
    - Storage full (>90%)

- [ ] 6.3 Security Hardening
  - [ ] Review Frigate pod security context (non-root if possible)
  - [ ] Implement Pod Security Standards
  - [ ] Enable HTTPS for Frigate web UI (already via Ingress)
  - [ ] Restrict camera network access (VLAN isolation)
  - [ ] Audit camera firmware version (update if needed)

- [ ] 6.4 Documentation
  - [ ] Document camera RTSP URLs (in SOPS encrypted file)
  - [ ] Document Frigate configuration rationale
  - [ ] Create troubleshooting guide
  - [ ] Document common maintenance tasks:
    - Adjusting detection settings
    - Adding new cameras
    - Reviewing events
    - Exporting clips

- [ ] 6.5 User Guide
  - [ ] Write user guide for reviewing events
  - [ ] Document how to export video clips
  - [ ] Document mobile app setup (if used)
  - [ ] Create FAQ for common issues

#### Expected Outcome
- Frigate deployment production-ready
- Monitoring and alerting configured
- Documentation complete
- Backup strategy implemented

### Phase 7: NPU Acceleration (Future Enhancement)

**Objective**: Build custom YOLO-TFLite detection service to enable NPU-accelerated object detection for Frigate using mainline kernel stack.

**Status**: 🔮 **PLANNED** - Future work after Frigate is stable with CPU detector

#### 7.1 Research and Planning

**Tasks:**
- [ ] Research YOLO model compatibility with TensorFlow Lite
  - YOLOv5 TFLite conversion
  - YOLOv8 TFLite conversion
  - YOLO-NAS TFLite conversion
  - Evaluate which models work best with Mesa Teflon

- [ ] Study Frigate HTTP detector protocol
  - Request format (image input)
  - Response format (bounding boxes, scores, class IDs)
  - Performance requirements
  - Error handling

- [ ] Analyze Mesa Teflon YOLO support
  - Which YOLO operations are supported by Teflon?
  - Test YOLO inference on existing npu-inference service
  - Measure baseline performance

#### 7.2 Model Conversion and Testing

**Tasks:**
- [ ] Convert YOLO model to TFLite format
  - Select YOLO variant (YOLOv8n recommended for speed)
  - Export to ONNX format
  - Convert ONNX to TFLite
  - Quantize to INT8 (required for NPU)

- [ ] Test YOLO TFLite on NPU
  - Load model in existing npu-inference container
  - Run test inference on sample images
  - Verify NPU acceleration (check inference time <40ms)
  - Parse output tensor to extract bounding boxes

- [ ] Validate detection accuracy
  - Test with COCO validation set
  - Compare accuracy vs original YOLO model
  - Ensure acceptable accuracy after quantization

#### 7.3 Custom Detection Service Development

**Tasks:**
- [ ] Design HTTP API specification
  ```
  POST /detect
  Content-Type: multipart/form-data

  Request: image file
  Response: {
    "detections": [
      {
        "box": [x1, y1, x2, y2],  # Bounding box coordinates
        "score": 0.95,             # Confidence score
        "class_id": 0,             # COCO class ID
        "class_name": "person"     # Human-readable label
      }
    ],
    "inference_time_ms": 28.5
  }
  ```

- [ ] Implement detection service (based on npu-inference)
  - Fork npu-inference codebase
  - Replace MobileNetV1 classification with YOLO detection
  - Implement bounding box parsing (NMS, coordinate conversion)
  - Add `/detect` endpoint
  - Keep existing `/health` and `/metrics` endpoints

- [ ] Build container image
  - Dockerfile with TFLite, Pillow, NumPy
  - Include YOLO TFLite model
  - Mesa Teflon from host mount (same as npu-inference)

- [ ] Test locally with Podman
  ```bash
  podman run -d \
    --device=/dev/accel/accel0 \
    -v /run/opengl-driver/lib:/mesa-libs:ro \
    -v /nix/store:/nix/store:ro \
    -p 8080:8080 \
    yolo-tflite-detector:latest
  ```

#### 7.4 Kubernetes Deployment

**Tasks:**
- [ ] Create K8s manifests
  - `deployment.yaml` - YOLO detector on opi02
  - `service.yaml` - ClusterIP service
  - `servicemonitor.yaml` - Prometheus metrics
  - `kustomization.yaml`

- [ ] Deploy via ArgoCD
  - Create ArgoCD Application
  - Deploy to `ml` namespace
  - Verify pod starts on opi02 (dedicated NPU node)

- [ ] Test detection endpoint
  ```bash
  # From within cluster
  curl -X POST -F "image=@test.jpg" \
    http://yolo-detector.ml.svc.cluster.local:8080/detect
  ```

- [ ] Verify NPU acceleration
  - Check inference time <40ms
  - Verify bounding boxes are correct
  - Test with various images (person, cat, dog, car)

#### 7.5 Frigate Integration

**Tasks:**
- [ ] Update Frigate ConfigMap
  ```yaml
  detectors:
    yolo_tflite:
      type: http
      url: http://yolo-detector.ml.svc.cluster.local:8080/detect
  ```

- [ ] Restart Frigate pod (or hot-reload config)

- [ ] Verify Frigate uses HTTP detector
  - Check Frigate logs for HTTP detector calls
  - Verify objects detected correctly
  - Check Frigate stats page (inference time should be ~30-40ms)

- [ ] Performance comparison
  - CPU detector: ~60-100ms
  - HTTP + NPU detector: ~30-40ms (network overhead + inference)
  - Expected 2-3× speedup

#### 7.6 Optimization and Tuning

**Tasks:**
- [ ] Optimize inference performance
  - Test different YOLO model sizes (n, s, m)
  - Tune NPU core allocation (1 vs 3 cores)
  - Benchmark throughput (detections per second)

- [ ] Reduce HTTP overhead
  - Consider gRPC instead of HTTP (lower latency)
  - Optimize image transfer (compression, format)
  - Add connection pooling/keep-alive

- [ ] Multi-camera scaling
  - Test with multiple cameras calling same detector
  - Evaluate if additional detector instances needed
  - Consider load balancing across opi02 and opi03

#### Expected Outcome
- YOLO-TFLite detection service running on opi02 NPU
- Frigate using HTTP detector for NPU-accelerated inference
- Detection performance <40ms (2-3× faster than CPU)
- All services using mainline Mesa Teflon stack
- No vendor kernel dependencies

#### Success Criteria
- [ ] YOLO TFLite model loads and runs on NPU
- [ ] Inference time <40ms (including HTTP overhead)
- [ ] Detection accuracy acceptable for surveillance use case
- [ ] Frigate successfully uses HTTP detector
- [ ] Objects (person, cat, dog, bird) detected correctly
- [ ] System stable under continuous operation
- [ ] Prometheus metrics tracking detector performance

**Estimated Timeline**: 15-20 hours development + testing

## Integration with Existing NPU Infrastructure

### Relationship to NPU Integration Plan

This surveillance camera deployment builds on the existing NPU infrastructure documented in `rknn-npu-integration-plan.md`. Key integration points:

**Shared NPU Hardware:**
- Frigate will use the same RK3588 NPU cores as the npu-inference service
- Both use `/dev/accel/accel0` device
- Both require Mesa 25.3+ with rocket driver

**Different NPU Stacks:**

| Service | NPU Stack | Model Format | Inference Framework |
|---------|-----------|--------------|---------------------|
| **npu-inference** | Mesa Teflon (mainline) | TFLite (`.tflite`) | TensorFlow Lite |
| **Frigate** | RKNN (vendor) | RKNN (`.rknn`) | Rockchip RKNN Runtime |

⚠️ **Important Incompatibility**:
- The npu-inference service uses **Mesa Teflon** (mainline TensorFlow Lite delegate)
- Frigate uses **RKNN Runtime** (Rockchip vendor library)
- These are **mutually exclusive** on the same NPU device

**Resolution Strategy:**

⚠️ **CRITICAL**: Frigate's RKNN detector is **NOT compatible** with mainline kernel. RKNN requires vendor kernel which breaks Avalanche's mainline-only architecture.

**Deployment Approach:**

**Phase 1: CPU Detector (Initial Deployment)** ✅
```yaml
# Frigate deployment with CPU detector
detectors:
  cpu:
    type: cpu
    num_threads: 4

# Can run on any node (no NPU requirement)
nodeSelector:
  kubernetes.io/hostname: opi01  # Or opi02, opi03
```

**Benefits:**
- Works immediately on mainline kernel
- Validates Frigate deployment
- No NPU conflicts
- Sufficient performance for single camera

**Phase 2: Custom YOLO-TFLite Service (Future NPU Acceleration)** 🎯

Build custom object detection service using mainline NPU stack:

```yaml
# Custom YOLO-TFLite detection service
# Similar to existing npu-inference service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yolo-detector
  namespace: ml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: opi02  # Dedicated NPU node
      containers:
      - name: detector
        image: forge.internal/nemo/yolo-tflite-detector:latest
        # Mount /dev/accel/accel0, Mesa libs, etc.
```

```yaml
# Frigate uses HTTP detector to call custom service
detectors:
  yolo_tflite:
    type: http
    url: http://yolo-detector.ml.svc.cluster.local:8080/detect
```

**Node Allocation Strategy:**
- **opi01**: Frigate (CPU detector initially, then HTTP detector)
- **opi02**: YOLO-TFLite detection service (NPU acceleration)
- **opi03**: Existing npu-inference service (image classification)

**Benefits:**
- All services use mainline Mesa Teflon stack ✅
- No vendor kernel required ✅
- Frigate gets NPU acceleration via HTTP ✅
- Each NPU node dedicated to one service ✅
- Maintains architectural consistency ✅

**Implementation Timeline:**
1. Deploy Frigate with CPU detector (validate functionality)
2. Research YOLO TFLite conversion and Mesa Teflon compatibility
3. Build custom YOLO-TFLite detection service (based on npu-inference)
4. Test object detection performance on RK3588 NPU
5. Switch Frigate to HTTP detector
6. Benchmark performance improvement vs CPU

## Storage Planning

### Storage Requirements

**Database** (`frigate-db` PVC):
- Size: 10GB
- Purpose: SQLite database (metadata, events, detections)
- Growth: ~100MB/month (low growth)
- Storage class: `local-path` or `longhorn`

**Recordings** (`frigate-recordings` PVC):
- Size: **Depends on retention policy**
- Purpose: Continuous or motion-based recording
- Growth: **Highly variable**

**Recording Size Estimation:**

| Retention Mode | Duration | Resolution | FPS | H.265 Bitrate | Storage/Day | Storage/Week |
|----------------|----------|------------|-----|---------------|-------------|--------------|
| **Continuous** | 24/7 | 2688×1520 | 15 | 4 Mbps | ~43 GB/day | ~300 GB/week |
| **Motion Only** | ~2 hrs/day | 2688×1520 | 15 | 4 Mbps | ~3.6 GB/day | ~25 GB/week |
| **Events Only** | ~30 min/day | 2688×1520 | 15 | 4 Mbps | ~0.9 GB/day | ~6 GB/week |

**Recommended Configuration:**
- **Mode**: Motion detection recording
- **Retention**: 7 days
- **Storage**: 50GB (with headroom)

**Clips/Events** (`frigate-clips` PVC or same as recordings):
- Size: 10-20GB
- Purpose: Short clips of detected events
- Retention: 14 days (configurable)

**Total Storage Estimate:**
- Database: 10GB
- Recordings: 50GB (7 days motion)
- Clips: 10GB (14 days events)
- **Total**: 70GB minimum, **100GB recommended**

### Storage Implementation

**Using Longhorn** (Recommended):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: frigate-recordings
  namespace: frigate
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
```

**Benefits:**
- Distributed across nodes (replicated)
- Automatic snapshots/backups
- Resizable (can expand if needed)

**Alternative: local-path** (Faster, not replicated):
- Use if Longhorn not available
- Data loss risk if node fails
- Better performance (local disk)

## Network Security Considerations

### Camera Network Isolation

**Recommended: VLAN Segmentation**

Isolate camera on separate VLAN to prevent:
- Camera accessing other devices (e.g., workstations, servers)
- Other devices accessing camera admin interface
- Camera "calling home" to cloud services

**VLAN Setup** (on router/switch):
- **Main LAN**: `10.1.0.0/24` (existing devices)
- **Camera VLAN**: `10.1.10.0/24` (cameras only)
- **Firewall Rules**:
  - Allow: Camera → Frigate (RTSP)
  - Allow: Admin workstation → Camera (HTTPS/web UI)
  - Deny: Camera → Internet
  - Deny: Camera → other devices

**If VLAN not available**:
- Disable camera internet access via firewall rules
- Monitor camera network activity (check router logs)
- Disable camera P2P/cloud features

### Camera Firmware Updates

**Security Best Practices:**
- Check Dahua website for firmware updates periodically
- **DO NOT** auto-update (test updates first)
- Download firmware from official source only
- Review changelog for security fixes
- Test update on camera in isolated network first

**Current Firmware** (as of purchase 2022):
- Likely outdated (2+ years old)
- Check for critical security patches
- Update if vulnerabilities found

## Troubleshooting Guide

### Camera Not Accessible on Network

**Symptoms:**
- Cannot ping camera IP
- Cannot access web UI
- nmap shows no open ports

**Diagnosis:**
```bash
# Check PoE switch port status (link up?)
# Check camera status LED (should be solid or blinking)
# Try direct connection (laptop → camera via PoE injector)

# Scan network
nmap -sn 10.1.0.0/24
```

**Fixes:**
- Verify PoE switch provides sufficient power (802.3af, 15.4W)
- Try different ethernet cable
- **Hardware factory reset** (see procedure below)
- Check if camera is on different subnet (use DHCP discovery tool)

**Hardware Factory Reset Procedure:**

The IPC-T5442TM-AS has an accessible reset button under the hatch where the microSD card slot is located.

**Method 1** (camera powered on):
1. Locate the small hatch on the camera body (SD card access)
2. Open the hatch to expose the reset button (tiny button near SD slot)
3. Press and hold the reset button for **at least 10 seconds**
4. Listen for the IR filter click (confirms reset)
5. Release button and wait for camera to reboot

**Method 2** (camera powered off):
1. Disconnect power from camera
2. Open hatch and press/hold reset button
3. While holding button, apply power to camera
4. Continue holding for **at least 60 seconds**
5. Release button and wait for camera to reboot

**After reset:**
- Camera returns to default IP: `192.168.1.108`
- Default credentials: `admin` / `admin`
- All settings erased (network, passwords, streams)
- Reconfigure camera from scratch

### RTSP Stream Fails or Stutters

**Symptoms:**
- VLC shows "connection failed"
- Stream drops every few seconds
- Frigate shows "ffmpeg errors"

**Diagnosis:**
```bash
# Test stream directly
ffplay -rtsp_transport tcp "rtsp://admin:password@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0"

# Check network bandwidth
iperf3 -c 10.1.0.50  # If camera supports iperf3 (unlikely)

# Check Frigate logs
kubectl logs -n frigate deployment/frigate | grep -i rtsp
```

**Fixes:**
- Reduce bitrate on camera (4 Mbps → 2 Mbps)
- Lower FPS (20 FPS → 15 FPS)
- Check network congestion (switch bandwidth)
- Use H.264 instead of H.265 (better compatibility)
- Increase I-frame interval (reduces bitrate spikes)

### Frigate Pod Fails to Start

**Symptoms:**
- Pod stuck in `CrashLoopBackOff`
- Pod shows `ImagePullBackOff`

**Diagnosis:**
```bash
# Check pod status
kubectl get pods -n frigate

# Check events
kubectl describe pod -n frigate <pod-name>

# Check logs
kubectl logs -n frigate <pod-name>
```

**Common Fixes:**
- **ImagePullBackOff**: Check image repository/tag in values.yaml
- **CrashLoopBackOff**: Check config.yaml syntax (invalid YAML)
- **Permission denied**: Check PVC permissions, security context
- **Device not found** (`/dev/accel/accel0`): Verify device mounts, node affinity

### NPU Not Accelerating (Slow Inference)

**Symptoms:**
- Frigate stats show >60ms detector inference time
- Expected ~25-30ms with RKNN on RK3588

**Diagnosis:**
```bash
# Check Frigate stats page
# http://frigate.internal/stats
# Look for "Detector inference time"

# Check detector logs
kubectl logs -n frigate deployment/frigate | grep -i rknn

# Verify NPU device
kubectl exec -n frigate deployment/frigate -- ls -la /dev/accel/accel0
```

**Fixes:**
- Verify RKNN libraries installed in container
- Check detector config (type: rknn, num_cores: 3)
- Verify NPU device mounted correctly
- Check node has NPU hardware (opi01-03)
- Fall back to CPU detector temporarily:
  ```yaml
  detectors:
    cpu:
      type: cpu
  ```

### High False Positive Rate

**Symptoms:**
- Frigate detects people when there are none
- Wind-blown bushes trigger motion

**Diagnosis:**
- Review events in Frigate UI
- Check detection bounding boxes
- Identify problematic zones/objects

**Fixes:**
- Increase `min_area` filter (larger objects only)
- Increase `threshold` (higher confidence required)
- Add motion masks (mask out trees, bushes)
- Configure zones (only detect in specific areas)
- Tune camera positioning (avoid problematic areas)
- Adjust camera settings (reduce noise, enable WDR)

## Success Criteria

### Phase 1-6: Frigate with CPU Detector (Initial Deployment)

- [x] Camera physically installed and powered (indoor test setup)
- [x] Camera accessible on network with static IP (10.0.0.50)
- [x] Default password changed, camera secured
- [x] RTSP streams tested and verified stable
- [x] Frigate deployed to Kubernetes cluster
- [x] Frigate pod running with CPU detector
- [x] Camera integrated with Frigate
- [x] Object detection working (person, cat, dog, bird) with CPU detector
- [x] Recordings and events saved correctly
- [x] Web UI accessible at `https://frigate.internal`
- [x] Authentication enabled (port 8971)
- [ ] Monitoring and alerting configured - *Phase 6 pending*
- [ ] Documentation complete - *Phase 6 pending*
- [ ] Outdoor permanent installation - *Phase 1 pending*

### Phase 7: NPU Acceleration (Future Enhancement)

- [ ] YOLO TFLite model running on NPU
- [ ] Custom detection service deployed to opi02
- [ ] Frigate HTTP detector configured
- [ ] NPU-accelerated inference <40ms (2-3× faster than CPU)
- [ ] Detection accuracy acceptable for surveillance
- [ ] All services using mainline Mesa Teflon stack
- [ ] No vendor kernel dependencies

## Timeline

No specific deadlines. Phases can be pursued at own pace:

### Initial Deployment (Phases 1-6)

- **Phase 1**: Camera Physical Setup (1-2 hours)
- **Phase 2**: Camera Configuration (2-4 hours)
- **Phase 3**: Frigate Deployment Planning (4-8 hours research/design)
- **Phase 4**: Frigate Kubernetes Deployment (4-6 hours)
- **Phase 5**: Camera Integration and Testing (2-4 hours)
- **Phase 6**: Production Readiness (4-8 hours)

**Subtotal**: 20-30 hours (CPU detector deployment)

### Future Enhancement (Phase 7)

- **Phase 7.1**: Research and Planning (4-6 hours)
- **Phase 7.2**: Model Conversion and Testing (4-6 hours)
- **Phase 7.3**: Custom Detection Service Development (6-8 hours)
- **Phase 7.4**: Kubernetes Deployment (2-3 hours)
- **Phase 7.5**: Frigate Integration (1-2 hours)
- **Phase 7.6**: Optimization and Tuning (3-5 hours)

**Subtotal**: 20-30 hours (NPU acceleration)

**Total Estimate**: 40-60 hours for complete deployment with NPU acceleration

## References

### Camera Documentation
- [Review: Dahua IPC-HDW5442TM-AS (Loryta IPC-T5442TM-AS)](https://ipcamtalk.com/threads/review-dahua-ipc-hdw5442tm-as-loryta-ipc-t5442tm-as-4mp-starlight.40828/)
- [Review-OEM 4mp AI Cam IPC-T5442TM-AS Starlight+](https://ipcamtalk.com/threads/review-oem-4mp-ai-cam-ipc-t5442tm-as-starlight.39203/)
- [Dahua RTSP Configuration Guide](https://www.videoexpertsgroup.com/glossary/dahua-rtsp)
- [Complete Dahua IP Camera Setup Guide](https://www.ispyconnect.com/camera/dahua)
- [Dahua Camera Reset Procedure](https://ipcamtalk.com/threads/dahua-camera-reset-proceedure.21858/)
- [IPC-T5442T-ZE Hardware Reset Guide](https://ipcamtalk.com/threads/ipc-t5442t-ze-how-to-hardware-reset.52383/)
- [Reset Instruction of Network Camera (PDF)](https://dahuawiki.com/images/1/1e/ResetIPCamera.pdf)

### Frigate Documentation
- [Frigate Official Website](https://frigate.video)
- [Frigate Documentation](https://docs.frigate.video/)
- [Frigate Recommended Hardware](https://docs.frigate.video/frigate/hardware/)
- [Frigate Object Detectors](https://docs.frigate.video/configuration/object_detectors/)
- [Frigate Helm Chart (Official)](https://github.com/blakeblackshear/blakeshome-charts/tree/master/charts/frigate)
- [Frigate Helm Chart on Artifact Hub](https://artifacthub.io/packages/helm/blakeblackshear/frigate)

### Hardware Acceleration
- [RockChip RK3588 Support Discussion (Frigate)](https://github.com/blakeblackshear/frigate/discussions/4418)
- [Frigate NVR with Coral TPU Guide](https://helgeklein.com/blog/frigate-nvr-with-object-detection-on-raspberry-pi-5-coral-tpu/)
- [Turbocharging Frigate with Google Coral TPU](https://pro-it.rocks/turbocharging-frigate-nvr-with-google-coral-tpu-performance-gains-and-energy-savings/)

### Related Avalanche Documentation
- `docs/rknn-npu-integration-plan.md` - RK3588 NPU integration with Mesa Teflon
- `docs/npu-inference-testing-guide.md` - NPU inference testing procedures
- `docs/npu-adding-models.md` - Adding new models to NPU service

### Community Resources
- [IP Cam Talk Forum](https://ipcamtalk.com/) - Dahua camera community
- [Frigate GitHub Discussions](https://github.com/blakeblackshear/frigate/discussions) - Frigate community support
- [r/frigate](https://www.reddit.com/r/frigate/) - Frigate subreddit

## Appendix A: Example Frigate Configuration

Complete example `config.yml` for reference:

```yaml
mqtt:
  enabled: false  # Enable if using Home Assistant
  # host: mosquitto.home-automation.svc.cluster.local
  # user: frigate
  # password: "{FRIGATE_MQTT_PASSWORD}"

detectors:
  rknn:  # Rockchip NPU detector
    type: rknn
    device: 0  # /dev/accel/accel0
    num_cores: 3  # Use all 3 NPU cores on RK3588

model:
  path: /config/model_cache/yolo_nas_s.rknn
  input_tensor: nchw
  input_pixel_format: bgr
  width: 640
  height: 640

database:
  path: /db/frigate.db

snapshots:
  enabled: True
  retain:
    default: 14

record:
  enabled: True
  retain:
    days: 7
    mode: motion
  events:
    retain:
      default: 14
      mode: active_objects

objects:
  track:
    - person
    - cat
    - dog
    - bird
  filters:
    person:
      min_area: 5000
      max_area: 100000
      threshold: 0.7
    cat:
      min_area: 2000
      max_area: 50000
      threshold: 0.6
    dog:
      min_area: 3000
      max_area: 80000
      threshold: 0.6
    bird:
      min_area: 500
      max_area: 10000
      threshold: 0.5

cameras:
  camera01:
    enabled: True

    ffmpeg:
      inputs:
        # High-quality recording stream (main stream)
        - path: rtsp://admin:{FRIGATE_CAMERA_PASSWORD}@10.1.0.50:554/cam/realmonitor?channel=1&subtype=0
          roles:
            - record

        # Low-quality detection stream (third stream)
        - path: rtsp://admin:{FRIGATE_CAMERA_PASSWORD}@10.1.0.50:554/cam/realmonitor?channel=1&subtype=2
          roles:
            - detect

    detect:
      enabled: True
      width: 640
      height: 480
      fps: 5

    snapshots:
      enabled: True
      retain:
        default: 14

    record:
      enabled: True
      retain:
        days: 7
        mode: motion
      events:
        retain:
          default: 14

    objects:
      track:
        - person
        - cat
        - dog
        - bird
      filters:
        person:
          min_area: 5000
          threshold: 0.7
        cat:
          min_area: 2000
          threshold: 0.6

    zones:
      garden:
        coordinates: 200,400,600,400,600,100,200,100  # x,y polygon (tune after install)
        objects:
          - cat
          - dog
          - bird

      driveway:
        coordinates: 700,400,1200,400,1200,100,700,100
        objects:
          - person
          - car

    motion:
      mask:
        # Mask out areas with constant motion (trees, bushes)
        # Format: x,y,x,y,x,y (polygon points)
        # - 1500,0,2688,0,2688,200,1500,200  # Top right corner (tree)
```

## Appendix B: Helm Values Example

Example `values.yaml` for Frigate Helm chart:

```yaml
image:
  repository: ghcr.io/blakeblackshear/frigate
  tag: stable  # Or specific version like 0.16.0
  pullPolicy: IfNotPresent

env:
  # Camera password (from secret)
  - name: FRIGATE_CAMERA_PASSWORD
    valueFrom:
      secretKeyRef:
        name: frigate-camera-credentials
        key: FRIGATE_CAMERA_PASSWORD

# Frigate configuration
config: |
  # Paste content from Appendix A here
  # Or mount ConfigMap

persistence:
  data:
    enabled: true
    storageClass: longhorn
    size: 10Gi
    accessMode: ReadWriteOnce

  recordings:
    enabled: true
    storageClass: longhorn
    size: 100Gi
    accessMode: ReadWriteOnce

resources:
  requests:
    memory: 1Gi
    cpu: 500m
  limits:
    memory: 4Gi
    cpu: 2000m

nodeSelector:
  kubernetes.io/hostname: opi01  # NPU node

# Mount NPU device
hostPath:
  devices:
    - /dev/accel/accel0
    - /dev/dri/renderD180

# NixOS specific: Mount Mesa libraries and nix store
volumes:
  - name: mesa-libs
    hostPath:
      path: /run/opengl-driver/lib
  - name: nix-store
    hostPath:
      path: /nix/store

volumeMounts:
  - name: mesa-libs
    mountPath: /mesa-libs
    readOnly: true
  - name: nix-store
    mountPath: /nix/store
    readOnly: true

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
  hosts:
    - host: frigate.internal
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: frigate-tls
      hosts:
        - frigate.internal

service:
  type: ClusterIP
  port: 5000

# ServiceMonitor for Prometheus
serviceMonitor:
  enabled: true
  interval: 30s
```

## Next Actions

### 🎯 Current Status (2026-02-01)

**✅ COMPLETED:**
- Phase 1: Camera network setup (indoor test, outdoor mounting pending)
- Phase 2: Camera configuration (static IP 10.0.0.50, password changed)
- Phase 3: Deployment planning
- Phase 4: Frigate Kubernetes deployment (CPU detector, port 8971 auth)
- Phase 5: Camera integration and basic testing

**Frigate is operational at `https://frigate.internal`**

---

### Remaining Tasks

#### Phase 1 (Pending): Outdoor Installation
- [ ] Choose permanent mounting location (garden view)
- [ ] Mount camera bracket to exterior wall
- [ ] Run ethernet cable from PoE switch
- [ ] Aim and level camera
- [ ] Document final cable routing

#### Phase 6 (Pending): Production Readiness
- [ ] Configure Prometheus ServiceMonitor
- [ ] Create Grafana dashboard
- [ ] Set up backup for Frigate database to S3 (Garage)
- [ ] Configure zones in Frigate (after outdoor install)
- [ ] Set up motion masks (after outdoor install)
- [ ] Add camera to local DNS as `camera01.internal`

---

### Future Enhancement (Phase 7 - NPU Acceleration)

**When ready to add NPU acceleration:**

1. **Research YOLO TFLite** (Phase 7.1)
   - Research YOLO model conversion to TFLite
   - Study Frigate HTTP detector protocol
   - Analyze Mesa Teflon YOLO operation support

2. **Convert and Test Model** (Phase 7.2)
   - Convert YOLOv8n to TFLite INT8 format
   - Test YOLO inference on existing npu-inference service
   - Verify NPU acceleration (<40ms inference)

3. **Build Custom Detection Service** (Phase 7.3)
   - Fork npu-inference codebase
   - Replace classification with object detection
   - Implement bounding box parsing (NMS)
   - Add `/detect` HTTP endpoint
   - Test locally with Podman

4. **Deploy and Integrate** (Phase 7.4-7.5)
   - Deploy YOLO-TFLite service to opi02 (dedicated NPU)
   - Update Frigate to use HTTP detector
   - Verify 2-3× speedup vs CPU (30-40ms vs 60-100ms)

**🚀 End result: NPU-accelerated Frigate with mainline-only architecture**

---

### Summary

**✅ Phase 1-5 COMPLETE**: Frigate running with CPU detector, camera streaming, authentication enabled

**⏳ Remaining**:
- Outdoor permanent installation (Phase 1)
- Monitoring and production hardening (Phase 6)
- NPU acceleration (Phase 7 - future)
