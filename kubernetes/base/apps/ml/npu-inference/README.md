# NPU Inference Service

HTTP inference service for RK3588 NPU-accelerated TensorFlow Lite inference using Mesa Teflon.

## Overview

This service provides HTTP endpoints for running **production-ready ML inference** on the RK3588 NPU hardware via the mainline Linux rocket driver and Mesa Teflon delegate.

**Model**: MobileNetV1 (quantized, INT8) - ImageNet-1000 object classification
**Hardware**: RK3588 NPU (3 cores, 6 TOPS combined)
**Performance**: ~13-16ms per inference with NPU acceleration
**Status**: ✅ Production-ready for real inference workloads

**What it can classify:**
- 1000 object categories from ImageNet (animals, vehicles, furniture, food, etc.)
- Accepts any image format/size - automatically preprocesses to 224x224
- Returns top 5 predictions with confidence scores in ~15ms

**Example real-world result:**
- Input: Cat photograph
- Output: "Egyptian cat", "tiger cat", "tabby" (correct classifications!)
- Inference time: 16.43ms

**⚠️ NixOS Important**: When running on NixOS hosts (like opi01-03), you **must** mount both `/run/opengl-driver/lib` AND `/nix/store` to allow the container to access Mesa Teflon libraries. See [Testing Locally](#testing-locally) section for correct mount configuration.

## Building the Image

From the repository root:

```bash
# Build the image
docker build -t npu-inference:latest \
  -f kubernetes/base/apps/ml/npu-inference/Dockerfile \
  .

# Or using podman (on NixOS hosts)
podman build -t npu-inference:latest \
  -f kubernetes/base/apps/ml/npu-inference/Dockerfile \
  .
```

## Testing Locally

Test on an Orange Pi 5 Plus node (opi01-03):

```bash
# SSH to node
ssh opi01.internal

# Run container with NPU device access (NixOS - requires /nix/store mount)
podman run -d \
  --name npu-test \
  --device=/dev/accel/accel0 \
  --device=/dev/dri/renderD180 \
  -v /run/opengl-driver/lib:/mesa-libs:ro \
  -v /nix/store:/nix/store:ro \
  -p 8080:8080 \
  npu-inference:latest

# Check logs (should show "Teflon delegate loaded successfully")
podman logs -f npu-test

# Test health endpoint
curl http://localhost:8080/health

# Create test image for inference testing
python3 -c "from PIL import Image; import numpy as np; \
  img = Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)); \
  img.save('test.jpg')"

# Run inference (should complete in ~13-16ms)
curl -X POST -F "image=@test.jpg" http://localhost:8080/infer

# Check metrics
curl http://localhost:8080/metrics

# Cleanup
podman stop npu-test && podman rm npu-test
```

### Understanding Test Images

**Why create a 224x224 random image?**

The test image creation command generates a random RGB image with dimensions matching MobileNetV1's input requirements:

```python
Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8))
```

- **224x224**: MobileNetV1's expected input resolution
- **3 channels**: RGB color image (Red, Green, Blue)
- **dtype=np.uint8**: Integer pixel values 0-255 (required for quantized models)
- **Random values**: Valid for performance testing; classification results will be meaningless but timing is accurate

**The server handles all preprocessing automatically:**
1. Accepts any image format (JPEG, PNG, BMP, GIF, etc.)
2. Accepts any image size (1920x1080, 640x480, etc.)
3. Converts to RGB if needed (handles grayscale, RGBA, etc.)
4. Resizes to 224x224 using bilinear interpolation
5. Converts to uint8 numpy array
6. Adds batch dimension for TFLite

**This means you can send any real image:**
```bash
# Any format, any size - server automatically preprocesses
curl -X POST -F "image=@my_photo.jpg" http://localhost:8080/infer
curl -X POST -F "image=@screenshot.png" http://localhost:8080/infer
curl -X POST -F "image=@cat_picture.webp" http://localhost:8080/infer
```

### Example Inference Session

```bash
# Start container
podman run -d --name npu-test \
  --device=/dev/accel/accel0 \
  --device=/dev/dri/renderD180 \
  -v /run/opengl-driver/lib:/mesa-libs:ro \
  -v /nix/store:/nix/store:ro \
  -p 8080:8080 \
  npu-inference:latest

# Wait for startup and check logs
sleep 3
podman logs npu-test | grep "Teflon delegate loaded"
# Expected: "✓ Teflon delegate loaded successfully"

# Create test image
python3 -c "from PIL import Image; import numpy as np; \
  img = Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)); \
  img.save('test.jpg')"

# Run inference
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq .

# Expected output:
# {
#   "success": true,
#   "predictions": [
#     {"class_id": 412, "score": 120.0},
#     {"class_id": 742, "score": 32.0},
#     ...
#   ],
#   "inference_time_ms": 14.93,
#   "shape": [1, 1001]
# }

# Run 10 inference tests to measure average performance
for i in {1..10}; do
  curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done

# Expected: most results between 12-17ms (NPU acceleration working)
# If results >50ms, NPU may not be accelerating

# Check overall metrics
curl -s http://localhost:8080/metrics

# Cleanup
podman stop npu-test && podman rm npu-test
```

## API Endpoints

### `GET /`
Root endpoint with API documentation and status.

**Response**:
```json
{
  "service": "NPU Inference Server",
  "hardware": "RK3588 NPU (Rockchip)",
  "model": "MobileNetV1 (quantized)",
  "endpoints": {...},
  "status": {
    "model_loaded": true,
    "total_inferences": 42,
    "avg_inference_time_ms": 13.45
  }
}
```

### `GET /health`
Health check endpoint for Kubernetes liveness/readiness probes.

**Response** (200 OK if healthy):
```json
{
  "status": "healthy",
  "model_loaded": true,
  "inference_count": 42
}
```

### `GET /metrics`
Prometheus-compatible metrics endpoint.

**Response** (text/plain):
```
npu_inference_total 42
npu_inference_time_seconds_total 0.563400
npu_inference_time_seconds_avg 0.013414
```

### `POST /infer`
Run inference on an uploaded image.

**Request**:
- Content-Type: `multipart/form-data`
- Body: Image file in `image` field (JPEG, PNG, etc.)

**Example**:
```bash
curl -X POST -F "image=@myimage.jpg" http://localhost:8080/infer
```

**Response** (200 OK):
```json
{
  "success": true,
  "predictions": [
    {"class_id": 285, "score": 127},
    {"class_id": 281, "score": 89},
    {"class_id": 282, "score": 45},
    {"class_id": 287, "score": 23},
    {"class_id": 283, "score": 12}
  ],
  "inference_time_ms": 13.42,
  "shape": [1, 1001]
}
```

**Note**: MobileNetV1 outputs 1001 ImageNet class logits (quantized INT8). To get human-readable labels, map class IDs to ImageNet labels using a label file.

## Production Use Cases

This service is **production-ready** for real inference workloads. Here are some practical applications:

### 1. Image Classification API
```bash
# User uploads photo, get object classification
curl -X POST -F "image=@user_photo.jpg" https://npu-inference.internal/infer
# Response includes top 5 object categories with confidence scores
```

**Use for:**
- Photo tagging and organization
- Asset management systems
- Image search/indexing
- Content categorization

### 2. Auto-Tagging Photo Libraries
```bash
# Batch process photo collection
for photo in ~/Photos/*.jpg; do
  RESULT=$(curl -s -X POST -F "image=@$photo" http://localhost:8080/infer)
  TOP_CLASS=$(echo "$RESULT" | jq -r '.predictions[0].class_id')
  echo "$photo: class $TOP_CLASS"
done
```

**Use for:**
- Organizing personal photo collections
- Digital asset management
- Photo gallery metadata generation

### 3. Content Moderation Pipeline
```bash
# Check uploaded images for specific content
RESPONSE=$(curl -s -X POST -F "image=@uploaded.jpg" http://localhost:8080/infer)
# Parse predictions, flag inappropriate or restricted objects
```

**Use for:**
- User-generated content moderation
- Compliance checking (restricted items)
- Safety filtering

### 4. Smart Home / IoT Integration
```bash
# Security camera snapshot analysis
curl -X POST -F "image=@camera_snapshot.jpg" http://npu-inference.internal/infer
# Identify objects in frame (person, vehicle, animal, package)
```

**Use for:**
- Smart doorbell object detection
- Wildlife camera identification
- Package delivery detection
- Intrusion detection

### 5. Web Application Backend
```python
# Python Flask/FastAPI backend
import requests

@app.post("/classify")
async def classify_image(file: UploadFile):
    files = {"image": (file.filename, file.file, file.content_type)}
    response = requests.post("http://npu-inference:8080/infer", files=files)
    return response.json()
```

**Use for:**
- Image upload classification
- E-commerce product recognition
- Social media photo analysis

### What Can Be Classified?

MobileNetV1 is trained on **ImageNet-1000** which includes:

**Animals** (398 classes):
- Dogs, cats, birds, reptiles, insects, fish
- Wild animals: lions, elephants, bears, etc.

**Vehicles** (10 classes):
- Cars, trucks, bicycles, motorcycles, airplanes, etc.

**Household Objects** (200+ classes):
- Furniture, appliances, utensils, electronics
- Food items, containers, tools

**Clothing & Accessories** (50+ classes):
- Shirts, dresses, hats, bags, shoes

**Nature** (100+ classes):
- Plants, flowers, trees, landscapes

**Technology** (50+ classes):
- Computers, phones, cameras, screens

**And more**: Sports equipment, musical instruments, buildings, etc.

**Full list**: See [ImageNet class list](https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt)

### Limitations

**What it CANNOT do:**
- ❌ Object detection with bounding boxes (use SSDLite MobileDet for this - Phase 3 enhancement)
- ❌ Face recognition / identification
- ❌ OCR / text reading
- ❌ Image generation
- ❌ Classify objects not in ImageNet-1000 (specialized domains)

**What it CAN do:**
- ✅ Classify 1000 common object categories
- ✅ Fast inference (~15ms per image)
- ✅ Process any image format/size
- ✅ Batch processing (sequential)
- ✅ HTTP API for easy integration

## Deploying to Kubernetes

The service is deployed to the K3s cluster via ArgoCD in the `ml` namespace.

### Accessing the Service

**Via Ingress** (recommended):
```bash
# Health check
curl -sk https://npu-inference.internal/health | jq .

# Run inference
curl -sk -X POST -F "image=@myimage.jpg" https://npu-inference.internal/infer | jq .

# Check metrics
curl -sk https://npu-inference.internal/metrics
```

**Via kubectl port-forward** (for testing):
```bash
# Forward service port
kubectl port-forward -n ml svc/npu-inference 8080:80

# In another terminal, test locally
curl http://localhost:8080/health
curl -X POST -F "image=@test.jpg" http://localhost:8080/infer
```

**From within cluster**:
```bash
# Use service DNS name
curl http://npu-inference.ml.svc.cluster.local/health
curl -X POST -F "image=@test.jpg" http://npu-inference.ml.svc.cluster.local/infer
```

### Monitoring

**Prometheus Metrics**:

Metrics are automatically scraped by Prometheus via ServiceMonitor:

```bash
# Query Prometheus for NPU metrics
# npu_inference_total - Total number of inferences
# npu_inference_time_seconds_avg - Average inference time
# npu_inference_time_seconds_total - Cumulative inference time

# View metrics directly
curl -sk https://npu-inference.internal/metrics
```

**Grafana Dashboard**:

A pre-configured Grafana dashboard is automatically deployed showing:
- Total inference count
- Average inference time (with thresholds: green <20ms, yellow <50ms, red >50ms)
- Inference rate (requests per second)
- Inference count over time graph
- Inference latency over time graph

Access the dashboard in Grafana:
1. Navigate to Grafana (typically at `https://grafana.internal`)
2. Search for "NPU Inference Service" dashboard
3. Dashboard UID: `npu-inference`

### Deployment Details

- **Namespace**: `ml`
- **Replica**: 1 (pinned to opi01 node)
- **Image**: `forge.internal/nemo/npu-inference:latest`
- **Ingress**: `npu-inference.internal` (HTTPS with step-ca certificate)
- **Resources**:
  - Requests: 500m CPU, 512Mi memory
  - Limits: 1 CPU, 1Gi memory

### Troubleshooting Kubernetes Deployment

**Check pod status:**
```bash
kubectl get pods -n ml -l app.kubernetes.io/name=npu-inference
```

**View logs:**
```bash
kubectl logs -n ml -l app.kubernetes.io/name=npu-inference --tail=50
```

**Verify NPU device access:**
```bash
kubectl exec -n ml deployment/npu-inference -- ls -la /dev/accel/accel0
```

**Check Teflon library:**
```bash
kubectl exec -n ml deployment/npu-inference -- ls -la /mesa-libs/libteflon.so
```

**Test inference from within cluster:**
```bash
kubectl run curl-test --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST -F "image=@/tmp/test.jpg" http://npu-inference.ml.svc.cluster.local/infer
```

See Phase 3.3 in `docs/rknn-npu-integration-plan.md` for detailed deployment manifests and architecture.

## Environment Variables

- `MODEL_PATH`: Path to TFLite model file (default: `/app/models/mobilenet_v1_1.0_224_quant.tflite`)
- `PORT`: HTTP server port (default: `8080`)
- `LD_LIBRARY_PATH`: Must include `/mesa-libs` for Teflon delegate (set in Dockerfile)

## Requirements

**Host Requirements**:
- Linux kernel 6.18+ with rocket driver
- Mesa 25.3+ with Teflon delegate
- `/dev/accel/accel0` device (RK3588 NPU)
- `/dev/dri/renderD180` device (udev symlink to accel0)
- User in `render` group (GID 303)

**Container Mounts**:
- `--device=/dev/accel/accel0` - NPU device
- `--device=/dev/dri/renderD180` - DRM render device
- `-v /run/opengl-driver/lib:/mesa-libs:ro` - Mesa Teflon library

## Troubleshooting

### Model not loading
- Check that `/app/models/mobilenet_v1_1.0_224_quant.tflite` exists in container
- Verify image was built correctly: `podman exec npu-test ls -la /app/models/`

### Teflon delegate not found
- Verify host has Mesa 25.3+: `ssh opi01.internal 'ls -la /run/opengl-driver/lib/libteflon.so'`
- Check container mount: `podman exec npu-test ls -la /mesa-libs/libteflon.so`
- Verify symlink target is accessible: `podman exec npu-test ls -la /nix/store/*mesa*/lib/libteflon.so` (NixOS)
- Verify LD_LIBRARY_PATH: `podman exec npu-test env | grep LD_LIBRARY_PATH`
- **NixOS users**: Ensure both `/run/opengl-driver/lib` AND `/nix/store` are mounted

### NPU device not accessible
- Check device exists on host: `ssh opi01.internal 'ls -la /dev/accel/accel0'`
- Check permissions: Should be `crw-rw-rw-` (mode 0666)
- Verify container can see device: `podman exec npu-test ls -la /dev/accel/accel0`

### Slow inference (>50ms)
- NPU may not be accelerating - check logs for Teflon loading messages
- Verify kernel driver loaded: `ssh opi01.internal 'lsmod | grep rocket'`
- Check dmesg for rocket errors: `ssh opi01.internal 'sudo dmesg | grep rocket'`

### Python/TensorFlow errors
- Ensure TensorFlow version is compatible (tested with 2.15.0)
- Check Python version: `podman exec npu-test python3 --version` (should be 3.11+)

## Performance Benchmarking

Run a load test to validate NPU performance:

```bash
# Simple sequential benchmark
for i in {1..100}; do
  curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done | awk '{sum+=$1; count+=1} END {print "Average:", sum/count, "ms"}'

# Check metrics after test
curl http://localhost:8080/metrics
```

**Expected Results**:
- Average inference time: 13-16ms
- 95th percentile: <20ms
- Throughput: ~60-70 requests/second (single NPU core)

## Adding Additional Models

The service currently uses **MobileNetV1** (2017, 70.6% accuracy) for validation and testing.

**For better accuracy**, consider adding **EfficientNet-Lite4** (2020, 80.4% accuracy):
- Step-by-step guide: `docs/npu-adding-models.md`
- Expected inference time: ~30ms (vs 16ms for MobileNetV1)
- Trade-off: +10% accuracy for +14ms latency
- Still well under <50ms target

The guide covers:
- Downloading and adding EfficientNet-Lite models
- Updating the Dockerfile and inference server
- Testing and comparing multiple models
- Alternative model options and compatibility requirements

## License

Part of the Avalanche infrastructure repository.
