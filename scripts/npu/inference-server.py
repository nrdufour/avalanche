#!/usr/bin/env python3
"""
NPU Inference HTTP Server
Provides HTTP API for RK3588 NPU-accelerated TensorFlow Lite inference
"""
import os
import sys
import time
import io
import logging
from pathlib import Path

import numpy as np
from PIL import Image
from flask import Flask, request, jsonify

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Try to import TFLite
try:
    try:
        import tflite_runtime.interpreter as tflite
        logger.info("Using tflite_runtime")
        USE_FULL_TF = False
    except ImportError:
        import tensorflow as tf
        logger.info("Using tensorflow.lite")
        USE_FULL_TF = True
except ImportError:
    logger.error("Neither tflite-runtime nor tensorflow installed")
    sys.exit(1)

# Flask app
app = Flask(__name__)

# Global state
interpreter = None
input_details = None
output_details = None
model_loaded = False
inference_count = 0
total_inference_time = 0.0

def find_teflon_library():
    """Find Teflon library using multiple strategies"""
    # Strategy 1: Check /run/opengl-driver (mounted from host)
    opengl_paths = [
        '/mesa-libs/libteflon.so',  # Container mount point
        '/run/opengl-driver/lib/libteflon.so',  # Host location
    ]

    for path in opengl_paths:
        if os.path.exists(path):
            real_path = os.path.realpath(path)
            logger.info(f"Found Teflon library: {path} -> {real_path}")
            return path

    # Strategy 2: Search common paths
    import glob
    patterns = [
        '/usr/lib/*/libteflon.so',
        '/usr/local/lib/libteflon.so',
        '/nix/store/*mesa*/lib/libteflon.so',
    ]

    for pattern in patterns:
        matches = glob.glob(pattern)
        if matches:
            logger.info(f"Found Teflon via pattern {pattern}: {matches[0]}")
            return matches[0]

    logger.error("Could not find libteflon.so")
    logger.error("Tried: /mesa-libs/libteflon.so, /run/opengl-driver/lib/libteflon.so")
    return None

def load_model(model_path='/app/models/mobilenet_v1_1.0_224_quant.tflite'):
    """Load TFLite model with Teflon delegate"""
    global interpreter, input_details, output_details, model_loaded

    if not os.path.exists(model_path):
        logger.error(f"Model not found: {model_path}")
        return False

    # Find Teflon library
    teflon_lib = find_teflon_library()
    if not teflon_lib:
        logger.error("Teflon library not found, NPU acceleration unavailable")
        return False

    try:
        # Load delegate
        if USE_FULL_TF:
            delegates = [tf.lite.experimental.load_delegate(teflon_lib)]
            interpreter = tf.lite.Interpreter(
                model_path=model_path,
                experimental_delegates=delegates
            )
        else:
            delegates = [tflite.load_delegate(teflon_lib)]
            interpreter = tflite.Interpreter(
                model_path=model_path,
                experimental_delegates=delegates
            )

        logger.info("✓ Teflon delegate loaded successfully")

        # Allocate tensors
        interpreter.allocate_tensors()
        input_details = interpreter.get_input_details()
        output_details = interpreter.get_output_details()

        logger.info(f"✓ Model loaded: {model_path}")
        logger.info(f"  Input shape: {input_details[0]['shape']}")
        logger.info(f"  Input dtype: {input_details[0]['dtype']}")
        logger.info(f"  Output shape: {output_details[0]['shape']}")

        model_loaded = True
        return True

    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        return False

def preprocess_image(image_data, target_size=(224, 224)):
    """
    Preprocess image for MobileNetV1 inference

    Args:
        image_data: PIL Image or bytes
        target_size: Target size (height, width)

    Returns:
        Preprocessed numpy array ready for inference
    """
    # Open image if bytes
    if isinstance(image_data, bytes):
        image = Image.open(io.BytesIO(image_data))
    else:
        image = image_data

    # Convert to RGB if necessary
    if image.mode != 'RGB':
        image = image.convert('RGB')

    # Resize to target size
    image = image.resize(target_size, Image.BILINEAR)

    # Convert to numpy array
    img_array = np.array(image, dtype=np.uint8)

    # Add batch dimension: (224, 224, 3) -> (1, 224, 224, 3)
    img_array = np.expand_dims(img_array, axis=0)

    return img_array

def run_inference(image_data):
    """
    Run NPU inference on preprocessed image

    Args:
        image_data: Preprocessed numpy array

    Returns:
        Tuple of (output_array, inference_time_ms)
    """
    global inference_count, total_inference_time

    if not model_loaded:
        raise RuntimeError("Model not loaded")

    start_time = time.time()

    # Set input tensor
    interpreter.set_tensor(input_details[0]['index'], image_data)

    # Run inference
    interpreter.invoke()

    # Get output tensor
    output_data = interpreter.get_tensor(output_details[0]['index'])

    inference_time_ms = (time.time() - start_time) * 1000

    # Update metrics
    inference_count += 1
    total_inference_time += inference_time_ms

    return output_data, inference_time_ms

# HTTP API Endpoints

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    status = {
        'status': 'healthy' if model_loaded else 'unhealthy',
        'model_loaded': model_loaded,
        'inference_count': inference_count
    }

    return jsonify(status), 200 if model_loaded else 503

@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus-style metrics endpoint"""
    avg_inference_time = total_inference_time / inference_count if inference_count > 0 else 0

    metrics_text = f"""# HELP npu_inference_total Total number of inferences
# TYPE npu_inference_total counter
npu_inference_total {inference_count}

# HELP npu_inference_time_seconds_total Total inference time in seconds
# TYPE npu_inference_time_seconds_total counter
npu_inference_time_seconds_total {total_inference_time / 1000:.6f}

# HELP npu_inference_time_seconds_avg Average inference time in seconds
# TYPE npu_inference_time_seconds_avg gauge
npu_inference_time_seconds_avg {avg_inference_time / 1000:.6f}
"""

    return metrics_text, 200, {'Content-Type': 'text/plain; version=0.0.4'}

@app.route('/infer', methods=['POST'])
def infer():
    """
    Run inference on uploaded image

    Expects:
        - multipart/form-data with 'image' field (JPEG/PNG file)
        OR
        - application/octet-stream (raw image bytes)

    Returns:
        JSON with classification results and timing
    """
    if not model_loaded:
        return jsonify({'error': 'Model not loaded'}), 503

    try:
        # Get image data
        if 'image' in request.files:
            image_file = request.files['image']
            image_data = image_file.read()
        elif request.data:
            image_data = request.data
        else:
            return jsonify({'error': 'No image provided'}), 400

        # Preprocess image
        preprocessed = preprocess_image(image_data)

        # Run inference
        output, inference_time = run_inference(preprocessed)

        # Process output (MobileNetV1 outputs 1001 class logits for ImageNet)
        output_flat = output.flatten()
        top5_indices = np.argsort(output_flat)[-5:][::-1]

        predictions = [
            {
                'class_id': int(idx),
                'score': float(output_flat[idx])
            }
            for idx in top5_indices
        ]

        result = {
            'success': True,
            'predictions': predictions,
            'inference_time_ms': round(inference_time, 2),
            'shape': output.shape
        }

        logger.info(f"Inference completed in {inference_time:.2f}ms")

        return jsonify(result), 200

    except Exception as e:
        logger.error(f"Inference error: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/', methods=['GET'])
def index():
    """Root endpoint with API documentation"""
    docs = {
        'service': 'NPU Inference Server',
        'hardware': 'RK3588 NPU (Rockchip)',
        'model': 'MobileNetV1 (quantized)',
        'endpoints': {
            'GET /': 'This documentation',
            'GET /health': 'Health check',
            'GET /metrics': 'Prometheus metrics',
            'POST /infer': 'Run inference (multipart/form-data with image field)'
        },
        'status': {
            'model_loaded': model_loaded,
            'total_inferences': inference_count,
            'avg_inference_time_ms': round(total_inference_time / inference_count, 2) if inference_count > 0 else 0
        }
    }

    return jsonify(docs), 200

if __name__ == '__main__':
    # Load model on startup
    logger.info("Starting NPU Inference Server...")

    model_path = os.getenv('MODEL_PATH', '/app/models/mobilenet_v1_1.0_224_quant.tflite')

    if load_model(model_path):
        logger.info("✓ Server ready")
    else:
        logger.error("✗ Failed to load model, server running in degraded state")

    # Start Flask server
    port = int(os.getenv('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False)
