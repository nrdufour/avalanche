FROM python:3.14-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
    numpy==1.24.3 \
    pillow==10.0.0 \
    tensorflow==2.15.0 \
    flask==3.0.0

# Create app directory
WORKDIR /app

# Download MobileNetV1 quantized model at build time
RUN mkdir -p /app/models && \
    cd /app/models && \
    wget -q https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz && \
    tar --no-same-owner -xzf mobilenet_v1_1.0_224_quant.tgz && \
    rm mobilenet_v1_1.0_224_quant.tgz && \
    echo "Model downloaded: $(ls -lh mobilenet_v1_1.0_224_quant.tflite)"

# Copy inference server application
COPY scripts/npu/inference-server.py /app/server.py

# Mesa Teflon library will be mounted from host at /mesa-libs
# This allows the container to use the host's NPU-enabled Mesa drivers
ENV LD_LIBRARY_PATH=/mesa-libs:$LD_LIBRARY_PATH

# Expose HTTP port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

# Run inference server
CMD ["python3", "server.py"]
