# Adding Models to NPU Inference Service

This guide explains how to add additional TensorFlow Lite models to the NPU inference service for comparison and testing.

## Current Setup

**Model**: MobileNetV1 (quantized INT8)
- **Accuracy**: ~70.6% ImageNet top-1
- **Inference time**: 16-18ms on RK3588 NPU
- **Size**: 4.3MB
- **Year**: 2017
- **Use case**: Baseline testing, validation

## Recommended Upgrade: EfficientNet-Lite4

**Why EfficientNet-Lite4?**
- **Accuracy**: 80.4% ImageNet top-1 (+10% vs MobileNetV1)
- **Inference time**: ~30ms expected (still <50ms target)
- **Size**: ~16MB quantized
- **Year**: 2020
- **Hardware optimized**: Designed for edge devices with INT8 quantization
- **Proven compatibility**: Used on similar ARM NPU hardware
- **Operations**: Uses RELU6 (Teflon compatible), no squeeze-excite

**Key improvements over MobileNetV1**:
- Better accuracy on real-world images
- More robust feature extraction
- Modern architecture optimizations
- Still fast enough for real-time use

## How to Add EfficientNet-Lite4

### Step 1: Download the Model

**Pre-quantized INT8 model** (recommended):

```bash
# From TensorFlow Cloud TPU checkpoints
wget -O efficientnet-lite4-int8.tflite \
  https://storage.googleapis.com/cloud-tpu-checkpoints/efficientnet/lite/efficientnet-lite4-int8.tflite
```

**Alternative sources**:
- TensorFlow Model Garden: https://github.com/tensorflow/tpu/tree/master/models/official/efficientnet/lite
- TensorFlow Hub: Search for "efficientnet-lite4 tflite int8"

**Verify download**:
```bash
# Check file size (~16MB for quantized version)
ls -lh efficientnet-lite4-int8.tflite

# Optional: inspect model metadata
python3 -c "
import tensorflow as tf
interpreter = tf.lite.Interpreter(model_path='efficientnet-lite4-int8.tflite')
print('Input details:', interpreter.get_input_details())
print('Output details:', interpreter.get_output_details())
"
```

### Step 2: Update Dockerfile

Add model download to the Dockerfile:

```dockerfile
# Download MobileNetV1 quantized model and ImageNet labels at build time
RUN mkdir -p /app/models && \
    cd /app/models && \
    # MobileNetV1 (existing)
    wget -q https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz && \
    tar --no-same-owner -xzf mobilenet_v1_1.0_224_quant.tgz && \
    rm mobilenet_v1_1.0_224_quant.tgz && \
    # EfficientNet-Lite4 (new)
    wget -q -O efficientnet-lite4-int8.tflite \
      https://storage.googleapis.com/cloud-tpu-checkpoints/efficientnet/lite/efficientnet-lite4-int8.tflite && \
    # ImageNet labels (shared by both models)
    wget -q -O imagenet_labels.txt https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt && \
    echo "MobileNetV1 downloaded: $(ls -lh mobilenet_v1_1.0_224_quant.tflite)" && \
    echo "EfficientNet-Lite4 downloaded: $(ls -lh efficientnet-lite4-int8.tflite)" && \
    echo "Labels downloaded: $(wc -l < imagenet_labels.txt) lines"
```

### Step 3: Update Inference Server

**Option A: Add `/infer-v2` endpoint** (recommended for comparison):

Add a new endpoint that uses EfficientNet-Lite4:

```python
# In scripts/npu/inference-server.py

# Global state - add second model
interpreter_v1 = None  # MobileNetV1
interpreter_v2 = None  # EfficientNet-Lite4
input_details_v1 = None
input_details_v2 = None
output_details_v1 = None
output_details_v2 = None

def load_efficientnet_lite4(model_path='/app/models/efficientnet-lite4-int8.tflite'):
    """Load EfficientNet-Lite4 model"""
    global interpreter_v2, input_details_v2, output_details_v2

    # Similar to load_model() but for second interpreter
    # ... (copy load_model logic)

    return True

# New endpoint
@app.route('/infer-v2', methods=['POST'])
def infer_v2():
    """Run inference using EfficientNet-Lite4"""
    # Similar to /infer but uses interpreter_v2
    # ... (copy infer logic, use interpreter_v2)
    pass

# Load both models at startup
if __name__ == '__main__':
    load_imagenet_labels()
    load_model()  # MobileNetV1
    load_efficientnet_lite4()  # EfficientNet-Lite4
    app.run(...)
```

**Option B: Replace existing model** (simpler):

Replace the model path in environment variable or code:

```python
# Change default model path
model_path = os.getenv('MODEL_PATH', '/app/models/efficientnet-lite4-int8.tflite')
```

**Option C: Model selector via query parameter**:

```python
@app.route('/infer', methods=['POST'])
def infer():
    model = request.args.get('model', 'mobilenet_v1')

    if model == 'efficientnet_lite4':
        interpreter = interpreter_v2
        input_details = input_details_v2
        output_details = output_details_v2
    else:
        interpreter = interpreter_v1
        input_details = input_details_v1
        output_details = output_details_v1

    # Rest of inference logic...
```

### Step 4: Test Locally

Build and test with both models:

```bash
# Build image
podman build -t npu-inference:efficientnet \
  -f kubernetes/base/apps/ml/npu-inference/Dockerfile \
  .

# Run on opi01
ssh opi01.internal
podman run -d --name npu-test \
  --device=/dev/accel/accel0 \
  --device=/dev/dri/renderD180 \
  -v /run/opengl-driver/lib:/mesa-libs:ro \
  -v /nix/store:/nix/store:ro \
  -p 8080:8080 \
  npu-inference:efficientnet

# Test MobileNetV1 (existing)
curl -X POST -F "image=@cat.jpg" http://localhost:8080/infer | jq .

# Test EfficientNet-Lite4 (new)
curl -X POST -F "image=@cat.jpg" http://localhost:8080/infer-v2 | jq .

# Compare inference times
for i in {1..10}; do
  curl -s -X POST -F "image=@cat.jpg" http://localhost:8080/infer | jq -r '.inference_time_ms'
done | awk '{sum+=$1; count+=1} END {print "MobileNetV1 avg:", sum/count, "ms"}'

for i in {1..10}; do
  curl -s -X POST -F "image=@cat.jpg" http://localhost:8080/infer-v2 | jq -r '.inference_time_ms'
done | awk '{sum+=$1; count+=1} END {print "EfficientNet-Lite4 avg:", sum/count, "ms"}'
```

### Step 5: Deploy to Kubernetes

Once tested locally, push changes and let Forgejo Actions rebuild:

```bash
git add kubernetes/base/apps/ml/npu-inference/Dockerfile scripts/npu/inference-server.py
git commit -m "feat(npu): add EfficientNet-Lite4 model for comparison"
git push
```

ArgoCD will automatically deploy the updated image.

**Test in production**:
```bash
# Test both models
curl -sk -X POST -F "image=@cat.jpg" https://npu-inference.internal/infer | jq '.predictions[0]'
curl -sk -X POST -F "image=@cat.jpg" https://npu-inference.internal/infer-v2 | jq '.predictions[0]'
```

### Step 6: Update Monitoring (Optional)

Add model-specific metrics:

```python
# In metrics endpoint
metrics_text = f"""# HELP npu_inference_total Total number of inferences
# TYPE npu_inference_total counter
npu_inference_total{{model="mobilenet_v1"}} {inference_count_v1}
npu_inference_total{{model="efficientnet_lite4"}} {inference_count_v2}

# HELP npu_inference_time_seconds_avg Average inference time in seconds
# TYPE npu_inference_time_seconds_avg gauge
npu_inference_time_seconds_avg{{model="mobilenet_v1"}} {avg_time_v1 / 1000:.6f}
npu_inference_time_seconds_avg{{model="efficientnet_lite4"}} {avg_time_v2 / 1000:.6f}
"""
```

Update Grafana dashboard to show both models with label filtering.

## Expected Performance

**MobileNetV1** (current):
- Inference time: 16-18ms
- Accuracy: ~70.6%
- Good for: Speed-critical applications

**EfficientNet-Lite4** (proposed):
- Inference time: ~30ms (estimated)
- Accuracy: ~80.4%
- Good for: Accuracy-critical applications, photo classification

**Trade-off**: +10% accuracy for ~12-14ms slower inference (still well under 50ms target)

## Other EfficientNet-Lite Variants

If 30ms is too slow, try smaller variants:

| Model | Accuracy | Expected Time | Use Case |
|-------|----------|---------------|----------|
| EfficientNet-Lite0 | 75.1% | ~8-10ms | Speed priority, better than MobileNetV1 |
| EfficientNet-Lite1 | 76.7% | ~12-15ms | Balanced |
| EfficientNet-Lite2 | 77.6% | ~16-20ms | Balanced |
| EfficientNet-Lite3 | 79.8% | ~22-26ms | Accuracy priority |
| EfficientNet-Lite4 | 80.4% | ~28-32ms | Best accuracy |

Download URL pattern:
```
https://storage.googleapis.com/cloud-tpu-checkpoints/efficientnet/lite/efficientnet-lite{0-4}-int8.tflite
```

## Alternative Models (Future)

### MobileNetV4 (2024) - Newest but Requires Work

**Published**: ECCV 2024 (Most recent!)
- **Accuracy**: 83% ImageNet top-1
- **Problem**: No pre-quantized INT8 TFLite models publicly available yet
- **Status**: Would need manual quantization

**If you want to try it** (advanced):

1. **Download PyTorch/TensorFlow weights**:
   - Official implementation: https://github.com/tensorflow/models/blob/master/official/vision/modeling/backbones/mobilenet.py
   - Hugging Face (Float32/Float16 only): https://huggingface.co/byoussef/MobileNetV4_Conv_Medium_TFLite_256

2. **Manually quantize to INT8**:
   ```python
   import tensorflow as tf

   # Load float model
   converter = tf.lite.TFLiteConverter.from_saved_model('mobilenetv4_saved_model/')

   # Enable INT8 quantization
   converter.optimizations = [tf.lite.Optimize.DEFAULT]
   converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]

   # Provide representative dataset for calibration
   def representative_dataset():
       for _ in range(100):
           # Generate random 224x224 images
           yield [np.random.rand(1, 224, 224, 3).astype(np.float32)]

   converter.representative_dataset = representative_dataset

   # Convert
   tflite_model = converter.convert()

   # Save
   with open('mobilenetv4-int8.tflite', 'wb') as f:
       f.write(tflite_model)
   ```

3. **Test with Mesa Teflon**:
   - Unknown if all operations are supported
   - Would need validation on RK3588 NPU
   - Might fall back to CPU for unsupported ops

**Recommendation**: Wait for official INT8 release or stick with EfficientNet-Lite4 (80.4% accuracy, proven to work).

**References**:
- Paper: https://dl.acm.org/doi/10.1007/978-3-031-73661-2_5
- Benchmarks: Included in MLPerf Mobile v4.0
- Code: https://github.com/tensorflow/models

### Other Options

**MobileNetV3** (2019):
- **Accuracy**: ~75%
- **Status**: Available with INT8 quantization
- **Problem**: Not significantly better than EfficientNet-Lite
- **Use case**: Only if you need slightly faster inference than Lite4

**Vision Transformer (ViT) models**:
- **Accuracy**: 80-85%+
- **Problem**: Too large/slow for RK3588 NPU (100-300ms+ inference)
- **Not recommended** for edge inference on this hardware

## Model Requirements for NPU Compatibility

For a model to work with Mesa Teflon + RK3588 NPU:

✅ **Required**:
- INT8 or INT16 quantized TFLite format
- Standard convolution operations
- RELU or RELU6 activations
- Standard pooling, addition operations

❌ **Not supported** (will fall back to CPU):
- SiLU/Swish activation (blocks YOLOv8)
- Some complex operations (check Mesa Teflon docs)
- Float32 models (no NPU acceleration)

**Validation**: Test inference time - if >50ms, likely falling back to CPU.

## Resources

- **EfficientNet-Lite Paper**: https://blog.tensorflow.org/2020/03/higher-accuracy-on-vision-models-with-efficientnet-lite.html
- **TensorFlow Lite Model Garden**: https://www.tensorflow.org/lite/models
- **Mesa Teflon Documentation**: https://docs.mesa3d.org/teflon.html
- **TFLite Quantization Guide**: https://www.tensorflow.org/lite/performance/post_training_integer_quant

## Troubleshooting

**Model not loading**:
- Verify file exists: `ls -la /app/models/efficientnet-lite4-int8.tflite`
- Check file size: Should be ~16MB for Lite4
- Verify it's INT8 quantized (not float32)

**Slow inference (>50ms)**:
- NPU may not be accelerating - check for unsupported operations
- Try smaller variant (Lite0-Lite3)
- Check Teflon delegate loaded: Look for "Teflon delegate loaded" in logs

**Different predictions than expected**:
- EfficientNet-Lite expects same 224x224 RGB input as MobileNetV1
- Uses same ImageNet labels (1001 classes)
- Higher accuracy should give better results on real images

**Memory issues**:
- Lite4 is larger (~16MB vs 4MB)
- May need to increase container memory limits
- Consider using smaller variant (Lite0-Lite2)
