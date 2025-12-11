# NPU Inference Service Testing Guide

Complete guide for testing the RK3588 NPU inference service with TensorFlow Lite and Mesa Teflon.

## Overview

This guide explains how to:
1. Create test images for inference
2. Send inference requests to the HTTP service
3. Interpret inference results
4. Verify NPU acceleration is working
5. Troubleshoot common issues

## Prerequisites

- NPU inference container running on opi01-03
- Python 3 with PIL (Pillow) and NumPy (for test image creation)
- curl for HTTP requests
- jq for JSON parsing (optional but recommended)

## Test Image Creation

### ⚠️ Important: Random Noise vs Real Images

There are **two types of test images** with different purposes:

| Type | Purpose | Classification Results | Use Case |
|------|---------|----------------------|----------|
| **Random Noise** | Performance testing | ❌ Meaningless (no real objects) | Validate NPU speed, benchmarking |
| **Real Images** | Actual inference | ✅ Meaningful (recognizes objects) | Production use, accuracy validation |

**Quick Comparison:**

**Random Noise Image:**
- Looks like TV static (random pixels)
- Model predicts nonsense (e.g., "apron" from pure noise)
- **Use for**: Speed testing, NPU verification, load testing
- **Don't use for**: Validating model accuracy, production inference

**Real Images:**
- Actual photos of cats, dogs, cars, objects
- Model predicts correctly (e.g., "Egyptian cat" from cat photo)
- **Use for**: Production inference, demonstrating capability, accuracy validation
- **This is what makes it useful!**

### Random Noise Images (Performance Testing Only)

For **performance testing and NPU speed validation**, create random RGB images:

```bash
# Create a single 224x224 test image
python3 -c "from PIL import Image; import numpy as np; \
  img = Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)); \
  img.save('test.jpg')"
```

**What this does:**
- `np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)` - Creates a 224x224x3 array of random bytes
- `(224, 224, 3)` - Height 224, Width 224, 3 color channels (RGB)
- `dtype=np.uint8` - Unsigned 8-bit integers (0-255, standard pixel values)
- `Image.fromarray(...)` - Converts NumPy array to PIL Image
- `img.save('test.jpg')` - Saves as JPEG file

**Why 224x224?**
- MobileNetV1 was trained on ImageNet at 224x224 resolution
- The model's input tensor expects exactly this size
- Server automatically resizes other sizes to 224x224

**Why random data?**
- Valid for testing inference performance (timing)
- Tests NPU acceleration without needing real images
- Classification results will be meaningless (no recognizable patterns)
- Useful for load testing and benchmarking

### Real Images (Production Inference)

The server accepts **any image format and size** and produces **meaningful classifications**. This is what makes the service **actually useful**!

#### Download Sample Test Images

```bash
# Cat (should classify as cat breeds)
curl -o cat.jpg https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/500px-Cat03.jpg

# Dog (should classify as dog breeds)
curl -o dog.jpg https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/Retriever_in_water.jpg/500px-Retriever_in_water.jpg

# Car (should classify as vehicle types)
curl -o car.jpg https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Placeholder_view_vector.svg/500px-Placeholder_view_vector.svg.png

# Coffee mug (should classify as cup/mug)
curl -o mug.jpg https://upload.wikimedia.org/wikipedia/commons/thumb/4/45/A_small_cup_of_coffee.JPG/500px-A_small_cup_of_coffee.JPG

# Or use your own images
ls ~/Pictures/*.jpg
```

#### Example: Cat Classification

```bash
# Run inference on cat image
curl -s -X POST -F "image=@cat.jpg" http://localhost:8080/infer | jq .

# Example output:
# {
#   "success": true,
#   "predictions": [
#     {"class_id": 286, "score": 171.0},  ← Egyptian cat
#     {"class_id": 283, "score": 45.0},   ← tiger cat
#     {"class_id": 282, "score": 28.0},   ← tabby
#     {"class_id": 281, "score": 18.0},   ← (another cat breed)
#     {"class_id": 287, "score": 12.0}    ← lynx
#   ],
#   "inference_time_ms": 16.43
# }
```

**Result**: All 5 predictions are cat-related! ✅ Model working correctly.

#### Looking Up Real Predictions

```bash
# Download ImageNet labels
curl -o ImageNetLabels.txt https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt

# Look up predictions for cat image
for class_id in 286 283 282 281 287; do
  line=$((class_id + 1))
  label=$(sed -n "${line}p" ImageNetLabels.txt)
  echo "Class $class_id: $label"
done

# Output:
# Class 286: Egyptian cat
# Class 283: tiger cat
# Class 282: tabby
# Class 281: Persian cat
# Class 287: lynx
```

#### Production Use Cases

**1. Image Classification API**
```bash
# User uploads photo, get object classification
curl -X POST -F "image=@user_photo.jpg" https://npu-inference.internal/infer
# Use predictions to tag/categorize images
```

**2. Content Moderation**
```bash
# Check if image contains specific objects
RESPONSE=$(curl -s -X POST -F "image=@uploaded.jpg" http://localhost:8080/infer)
# Parse predictions, flag inappropriate content
```

**3. Search/Tagging**
```bash
# Auto-tag photo collections
for photo in ~/Photos/*.jpg; do
  TAGS=$(curl -s -X POST -F "image=@$photo" http://localhost:8080/infer | \
    jq -r '.predictions[0].class_id')
  echo "$photo: class $TAGS"
done
```

**4. Object Detection Pipeline**
```bash
# First stage: classify overall scene with MobileNetV1
# Later: use SSDLite MobileDet for object detection (bounding boxes)
```

#### Supported Formats

- **JPEG/JPG** - Most common (recommended for photos)
- **PNG** - Lossless, good for screenshots
- **BMP** - Uncompressed
- **GIF** - Animated (uses first frame)
- **WEBP** - Modern compressed format
- **TIFF** - Professional photography
- Most formats supported by PIL/Pillow

#### Any Size Works

The server automatically preprocesses to 224x224:
- **4K images** (3840x2160) → resized to 224x224
- **Thumbnails** (100x100) → resized to 224x224
- **Non-square** (1920x1080) → resized (may slightly distort aspect ratio)
- **Vertical photos** (portrait orientation) → handled correctly

## Sending Inference Requests

### Basic Inference Request

```bash
# Send image for inference
curl -X POST -F "image=@test.jpg" http://localhost:8080/infer
```

**Breakdown:**
- `-X POST` - HTTP POST method
- `-F "image=@test.jpg"` - Send file as multipart/form-data with field name "image"
- `@test.jpg` - Read file content from test.jpg
- Output is JSON response

### Pretty-Printed Output

```bash
# Use jq for formatted JSON output
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq .

# Save response to file
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer > response.json
```

### Extract Specific Fields

```bash
# Get only inference time
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
# Output: 14.93

# Get top prediction
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq '.predictions[0]'
# Output: {"class_id": 412, "score": 120.0}

# Get all class IDs
curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq '.predictions[].class_id'
# Output: 412, 742, 736, 886, 609
```

## Understanding Response Format

### Example Response

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

### Field Descriptions

**`success`** (boolean)
- `true` - Inference completed successfully
- `false` - Would indicate an error (error message in `error` field instead)

**`predictions`** (array of objects)
- Top 5 predictions ranked by confidence score (highest first)
- Each prediction contains:
  - **`class_id`** (integer 0-1000): ImageNet class index
  - **`score`** (float): Quantized confidence score (INT8 output from model)

**`inference_time_ms`** (float)
- Time in milliseconds for **NPU inference only**
- Does NOT include:
  - HTTP request/response time
  - Image decoding/preprocessing
  - JSON serialization
- **Expected range**: 12-17ms for NPU acceleration
- **If >50ms**: NPU likely not accelerating (falling back to CPU)

**`shape`** (array)
- Output tensor shape: `[batch_size, num_classes]`
- `[1, 1001]` - 1 image, 1001 classes (ImageNet + background class)

### Understanding Class IDs and Scores

**Class IDs** are ImageNet-1000 class indices (0-1000):
- **0**: Background class (not an object)
- **1-1000**: Object categories from ImageNet dataset

**Scores** are quantized INT8 values:
- NOT normalized probabilities (not 0-1 range)
- NOT softmax-ed (not summing to 100%)
- Higher score = higher confidence
- Typical range: -128 to 127 (INT8) or 0-255 (UINT8)

**Important**: For random test images, class IDs and scores are meaningless (no real patterns to classify). Only use for timing validation.

## Mapping Class IDs to Labels

To get human-readable category names:

### Download ImageNet Labels

```bash
# Download label file (1001 lines, one per class)
wget https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt

# View labels
head ImageNetLabels.txt
# Output:
# background
# tench
# goldfish
# great white shark
# tiger shark
# ...
```

### Look Up Class Labels

```bash
# Get label for class_id 412 (line 413, 1-indexed file)
sed -n '413p' ImageNetLabels.txt
# Example output: "assault rifle"

# Get label for class_id 281
sed -n '282p' ImageNetLabels.txt
# Example output: "tabby cat"
```

### Automated Label Mapping Script

```bash
# Create label lookup script
cat > lookup_label.sh <<'EOF'
#!/bin/bash
# Usage: ./lookup_label.sh <class_id>
CLASS_ID=$1
LINE_NUM=$((CLASS_ID + 1))
LABEL=$(sed -n "${LINE_NUM}p" ImageNetLabels.txt)
echo "Class $CLASS_ID: $LABEL"
EOF

chmod +x lookup_label.sh

# Use it
./lookup_label.sh 412
# Output: Class 412: assault rifle

./lookup_label.sh 281
# Output: Class 281: tabby cat
```

### Full Inference with Labels

```bash
# Get predictions and look up labels
RESPONSE=$(curl -s -X POST -F "image=@cat.jpg" http://localhost:8080/infer)
echo "$RESPONSE" | jq -r '.predictions[] | "\(.class_id): \(.score)"' | while read line; do
  CLASS_ID=$(echo $line | cut -d: -f1)
  SCORE=$(echo $line | cut -d: -f2)
  LABEL=$(sed -n "$((CLASS_ID + 1))p" ImageNetLabels.txt)
  echo "[$SCORE] $LABEL (class $CLASS_ID)"
done

# Example output:
# [120.0] tabby cat (class 281)
# [89.0] Egyptian cat (class 285)
# [45.0] tiger cat (class 282)
# [23.0] Siamese cat (class 284)
# [12.0] lynx (class 287)
```

## Performance Testing

### Single Inference Test

```bash
# Single inference with timing
time curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'

# Output:
# 14.93
# real    0m0.152s  # Total time including HTTP/network
# user    0m0.012s
# sys     0m0.004s
```

**Note**: `inference_time_ms` (14.93ms) measures only NPU inference. `real` time (152ms) includes HTTP overhead, network latency, JSON parsing, etc.

### Multiple Inference Tests

```bash
# Run 10 inferences and show all times
for i in {1..10}; do
  curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done

# Expected output (NPU working):
# 20.19  ← First inference (warmup, slightly slower)
# 11.88
# 12.51
# 16.80
# 14.64
# 12.98
# 15.15
# 13.32
# 15.18
# 15.22
```

### Calculate Average Performance

```bash
# Run 100 inferences and calculate average
TIMES=$(for i in {1..100}; do
  curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done)

# Calculate average
echo "$TIMES" | awk '{sum+=$1; count+=1} END {print "Average:", sum/count, "ms"}'

# Expected output:
# Average: 14.8 ms
```

### Load Testing

```bash
# Concurrent requests (10 parallel)
seq 1 10 | xargs -P 10 -I {} curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'

# Note: With single NPU, concurrent requests will queue (no parallelism)
# Expect similar or slightly longer times due to queuing
```

## Verifying NPU Acceleration

### Performance Indicators

**NPU is working if:**
- ✅ Inference time: 12-17ms (typical range)
- ✅ First inference: 18-22ms (warmup overhead)
- ✅ Consistent timing across multiple runs (±3ms variance)
- ✅ Container logs show "Teflon delegate loaded successfully"

**NPU may NOT be working if:**
- ❌ Inference time: >50ms consistently
- ❌ Inference time: >100ms (likely CPU fallback)
- ❌ Container logs show "Could not find libteflon.so"
- ❌ Large variance in timing (10-200ms range)

### Check Container Logs

```bash
# View startup logs
podman logs npu-test | head -20

# Expected output includes:
# INFO - Using tensorflow.lite
# INFO - Found Teflon library: /mesa-libs/libteflon.so -> /nix/store/...-mesa-25.3.1/lib/libteflon.so
# INFO - ✓ Teflon delegate loaded successfully
# INFO - ✓ Model loaded: /app/models/mobilenet_v1_1.0_224_quant.tflite
# INFO - ✓ Server ready
```

### Check NPU Device on Host

```bash
# Verify NPU device exists
ssh opi01.internal 'ls -la /dev/accel/accel0'
# Expected: crw-rw-rw- 1 root render 261, 0 Dec 10 14:41 /dev/accel/accel0

# Check rocket driver loaded
ssh opi01.internal 'lsmod | grep rocket'
# Expected: rocket module listed

# Check NPU cores detected
ssh opi01.internal 'sudo dmesg | grep "rocket.*npu"'
# Expected: 3 NPU cores initialized
```

### Compare CPU vs NPU Performance

```bash
# Test with NPU acceleration (normal container)
AVG_NPU=$(for i in {1..20}; do
  curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done | awk '{sum+=$1; count+=1} END {print sum/count}')

echo "NPU average: $AVG_NPU ms"

# Expected: ~14-15ms
```

## Health and Metrics Endpoints

### Health Check

```bash
# Check service health
curl -s http://localhost:8080/health | jq .

# Expected output:
# {
#   "status": "healthy",
#   "model_loaded": true,
#   "inference_count": 42
# }
```

**Status codes:**
- **200 OK** - Service healthy, model loaded
- **503 Service Unavailable** - Model failed to load, service degraded

### Prometheus Metrics

```bash
# View metrics
curl -s http://localhost:8080/metrics

# Expected output:
# # HELP npu_inference_total Total number of inferences
# # TYPE npu_inference_total counter
# npu_inference_total 42
#
# # HELP npu_inference_time_seconds_total Total inference time in seconds
# # TYPE npu_inference_time_seconds_total counter
# npu_inference_time_seconds_total 0.626820
#
# # HELP npu_inference_time_seconds_avg Average inference time in seconds
# # TYPE npu_inference_time_seconds_avg gauge
# npu_inference_time_seconds_avg 0.014924
```

**Metrics explanation:**
- `npu_inference_total` - Total number of successful inferences since container start
- `npu_inference_time_seconds_total` - Cumulative time spent in inference (sum of all)
- `npu_inference_time_seconds_avg` - Average inference time per request

### API Documentation

```bash
# View API documentation
curl -s http://localhost:8080/ | jq .

# Output includes:
# - Service information
# - Hardware details (RK3588 NPU)
# - Model information (MobileNetV1)
# - Available endpoints
# - Current status (inferences run, average time)
```

## Troubleshooting

### Slow Inference (>50ms)

**Symptoms:**
- Inference time consistently >50ms
- Much slower than expected 13-16ms

**Diagnosis:**
```bash
# Check if Teflon loaded
podman logs npu-test | grep "Teflon delegate loaded"

# If no output, Teflon failed to load - check mounts
podman inspect npu-test | jq '.[0].Mounts'

# Should show both /mesa-libs and /nix/store mounts
```

**Fix:**
```bash
# Ensure both volume mounts present
podman run -d --name npu-test \
  --device=/dev/accel/accel0 \
  --device=/dev/dri/renderD180 \
  -v /run/opengl-driver/lib:/mesa-libs:ro \
  -v /nix/store:/nix/store:ro \
  -p 8080:8080 \
  npu-inference:latest
```

### "Could not find libteflon.so"

**Symptoms:**
- Container logs show error finding Teflon library
- Service starts but in "degraded state"

**Diagnosis:**
```bash
# Check if symlink exists in container
podman exec npu-test ls -la /mesa-libs/libteflon.so

# Check if symlink target is accessible
podman exec npu-test test -f /nix/store/*mesa*/lib/libteflon.so && echo "Found" || echo "Not found"
```

**Fix:**
- Ensure `/nix/store` is mounted (NixOS requirement)
- Verify host has Mesa 25.3+: `ls -la /run/opengl-driver/lib/libteflon.so`

### Connection Refused

**Symptoms:**
- `curl: (7) Failed to connect to localhost port 8080: Connection refused`

**Diagnosis:**
```bash
# Check if container is running
podman ps | grep npu-test

# Check container logs for startup errors
podman logs npu-test
```

**Fix:**
```bash
# Restart container if crashed
podman restart npu-test

# Or remove and recreate
podman stop npu-test && podman rm npu-test
# Then run create command again
```

### Invalid Image Error

**Symptoms:**
- HTTP 500 error
- Logs show PIL/image decoding errors

**Diagnosis:**
```bash
# Check if image file is valid
file test.jpg
# Should show: JPEG image data

# Try opening with PIL manually
python3 -c "from PIL import Image; Image.open('test.jpg').show()"
```

**Fix:**
- Ensure image file is valid and not corrupted
- Use supported format (JPEG, PNG, etc.)
- Recreate test image if needed

## Example Testing Scripts

### Comprehensive Test Script

```bash
#!/bin/bash
# comprehensive-npu-test.sh
# Tests NPU inference service thoroughly

set -e

echo "=== NPU Inference Service Test ==="
echo

# 1. Health check
echo "1. Health Check"
HEALTH=$(curl -s http://localhost:8080/health)
echo "$HEALTH" | jq .
STATUS=$(echo "$HEALTH" | jq -r '.status')
if [ "$STATUS" != "healthy" ]; then
  echo "ERROR: Service unhealthy"
  exit 1
fi
echo "✓ Service is healthy"
echo

# 2. Create test image
echo "2. Creating test image"
python3 -c "from PIL import Image; import numpy as np; \
  img = Image.fromarray(np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)); \
  img.save('test.jpg')"
echo "✓ Test image created: test.jpg"
echo

# 3. Single inference
echo "3. Single Inference Test"
RESPONSE=$(curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer)
echo "$RESPONSE" | jq .
TIME=$(echo "$RESPONSE" | jq -r '.inference_time_ms')
echo "Inference time: ${TIME}ms"

if (( $(echo "$TIME > 50" | bc -l) )); then
  echo "⚠ WARNING: Inference slower than expected (>50ms)"
  echo "  NPU may not be accelerating"
else
  echo "✓ Inference time acceptable (<50ms)"
fi
echo

# 4. Performance test (10 runs)
echo "4. Performance Test (10 inferences)"
TIMES=""
for i in {1..10}; do
  TIME=$(curl -s -X POST -F "image=@test.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms')
  TIMES="$TIMES\n$TIME"
  printf "  Run %2d: %6.2fms\n" $i $TIME
done

AVG=$(echo -e "$TIMES" | tail -n 10 | awk '{sum+=$1; count+=1} END {print sum/count}')
MIN=$(echo -e "$TIMES" | tail -n 10 | sort -n | head -1)
MAX=$(echo -e "$TIMES" | tail -n 10 | sort -n | tail -1)

echo
echo "Results:"
echo "  Average: ${AVG}ms"
echo "  Min: ${MIN}ms"
echo "  Max: ${MAX}ms"

if (( $(echo "$AVG < 20" | bc -l) )); then
  echo "✓ EXCELLENT: NPU acceleration working perfectly"
elif (( $(echo "$AVG < 50" | bc -l) )); then
  echo "✓ GOOD: NPU acceleration working"
else
  echo "✗ FAIL: NPU not accelerating (avg >50ms)"
  exit 1
fi
echo

# 5. Metrics check
echo "5. Metrics"
curl -s http://localhost:8080/metrics | grep -E "npu_inference"
echo

echo "=== All Tests Passed ==="
```

Make executable and run:
```bash
chmod +x comprehensive-npu-test.sh
./comprehensive-npu-test.sh
```

## Summary

**Key Takeaways:**
1. Random 224x224 RGB images are valid for performance testing
2. Server automatically preprocesses any real image (format, size)
3. Expected NPU inference time: 12-17ms
4. Class IDs map to ImageNet-1000 categories
5. Check logs for "Teflon delegate loaded successfully" to verify NPU
6. Performance >50ms indicates NPU may not be accelerating

**For Kubernetes Testing:**
Once deployed to K8s, replace `localhost:8080` with the Ingress URL:
```bash
curl -X POST -F "image=@test.jpg" https://npu-inference.internal/infer
```

All testing principles remain the same.
