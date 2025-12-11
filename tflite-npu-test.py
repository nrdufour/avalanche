#!/usr/bin/env python3
"""
TensorFlow Lite NPU Test Script
Tests RK3588 NPU acceleration via Mesa Teflon delegate
"""
import numpy as np
import time
import sys

try:
    # Try tflite_runtime first (lightweight), fall back to full tensorflow
    try:
        import tflite_runtime.interpreter as tflite
        print("Using tflite_runtime")
        USE_FULL_TF = False
    except ImportError:
        import tensorflow as tf
        print("Using tensorflow.lite")
        USE_FULL_TF = True
except ImportError:
    print("ERROR: Neither tflite-runtime nor tensorflow installed")
    print("On NixOS, python3 should have tensorflow-bin available")
    sys.exit(1)

# Find Teflon library path on NixOS
import subprocess
import os
import glob

# Try multiple strategies to find libteflon.so (in priority order)
TEFLON_LIB = None

# Strategy 1: Check /run/opengl-driver (canonical location for current graphics drivers)
opengl_paths = [
    '/run/opengl-driver/lib/libteflon.so',
    '/run/opengl-driver-32/lib/libteflon.so',
]

for path in opengl_paths:
    if os.path.exists(path):
        TEFLON_LIB = os.path.realpath(path)  # Follow symlink to actual file
        print(f"Found Teflon via opengl-driver: {path}")
        break

# Strategy 2: Check current system's hardware.graphics.package
if not TEFLON_LIB:
    try:
        # Query the current system's sw path
        result = subprocess.run(
            ['readlink', '-f', '/run/current-system/sw'],
            capture_output=True, text=True, timeout=2
        )
        system_sw = result.stdout.strip()
        if system_sw:
            # Try to find graphics packages in the system closure
            result = subprocess.run(
                ['nix-store', '-qR', system_sw],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.splitlines():
                if 'mesa' in line.lower() or 'graphics-drivers' in line:
                    teflon_path = os.path.join(line.strip(), 'lib/libteflon.so')
                    if os.path.exists(teflon_path):
                        TEFLON_LIB = teflon_path
                        print(f"Found Teflon in system closure: {line}")
                        break
    except Exception as e:
        print(f"Warning: Could not query system closure: {e}")

# Strategy 3: Fallback to searching nix store (least reliable)
if not TEFLON_LIB:
    print("Falling back to nix store search...")
    mesa_patterns = [
        '/nix/store/*mesa-25.3*/lib/libteflon.so',  # Prefer 25.3+
        '/nix/store/*mesa-25*/lib/libteflon.so',
        '/nix/store/*mesa*/lib/libteflon.so',
        '/nix/store/*graphics-drivers*/lib/libteflon.so',
    ]

    for pattern in mesa_patterns:
        matches = glob.glob(pattern)
        if matches:
            # Sort by path (later versions typically have higher hash/version)
            TEFLON_LIB = sorted(matches, reverse=True)[0]
            print(f"Found Teflon via pattern {pattern}")
            break

if not TEFLON_LIB or not os.path.exists(TEFLON_LIB):
    print("ERROR: Could not find libteflon.so")
    print("Mesa with Teflon support may not be installed")
    print("\nTried:")
    print("  1. /run/opengl-driver/lib/libteflon.so")
    print("  2. Current system closure via nix-store -qR")
    print("  3. Fallback nix store search for mesa-25.3+")
    sys.exit(1)

print(f"Using Teflon delegate: {TEFLON_LIB}")
print()

# Create interpreter with Teflon delegate
try:
    if USE_FULL_TF:
        # Full TensorFlow uses experimental.load_delegate
        delegates = [tf.lite.experimental.load_delegate(TEFLON_LIB)]
        interpreter = tf.lite.Interpreter(
            model_path="mobilenet_v1_1.0_224_quant.tflite",
            experimental_delegates=delegates
        )
    else:
        # tflite_runtime uses load_delegate directly
        delegates = [tflite.load_delegate(TEFLON_LIB)]
        interpreter = tflite.Interpreter(
            model_path="mobilenet_v1_1.0_224_quant.tflite",
            experimental_delegates=delegates
        )
    print("✓ Teflon delegate loaded successfully")
except Exception as e:
    print(f"ERROR loading Teflon delegate: {e}")
    sys.exit(1)

interpreter.allocate_tensors()
print("✓ Model loaded and tensors allocated")

# Get input/output details
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

print(f"✓ Input shape: {input_details[0]['shape']}")
print(f"✓ Input dtype: {input_details[0]['dtype']}")
print(f"✓ Output shape: {output_details[0]['shape']}")
print()

# Create dummy input (224x224x3 uint8 for MobileNetV1)
input_shape = input_details[0]['shape']
dummy_input = np.random.randint(0, 256, input_shape, dtype=np.uint8)

# Warm-up run
print("Warming up...")
interpreter.set_tensor(input_details[0]['index'], dummy_input)
interpreter.invoke()
print("✓ Warm-up complete")
print()

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
min_time = min(times)
max_time = max(times)

print()
print("=" * 60)
print(f"✓ Average inference time: {avg_time:.2f}ms")
print(f"✓ Min inference time: {min_time:.2f}ms")
print(f"✓ Max inference time: {max_time:.2f}ms")
print(f"✓ Output shape: {output.shape}")
print("=" * 60)

# Check if performance meets target
if avg_time < 50:
    print("✓ SUCCESS: Performance meets target (<50ms)")
    if avg_time <= 21:
        print("✓ EXCELLENT: Performance within expected range (16-21ms)")
else:
    print(f"⚠ WARNING: Performance slower than target (avg: {avg_time:.2f}ms, target: <50ms)")
