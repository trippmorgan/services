# Dragon Dictation Pro - GPU Server
# Optimized Dockerfile with layer caching and security improvements

FROM nvidia/cuda:12.4.1-base-ubuntu22.04

# Metadata
LABEL maintainer="trippmorgan"
LABEL version="6.0"
LABEL description="Dragon Dictation Pro - AI-powered medical transcription server"

# Set up the environment
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install system dependencies in a single layer
# Order: most stable packages first to maximize cache hits
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    wget \
    ca-certificates \
    && wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && rm cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libcudnn9-cuda-12 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy requirements first (for better layer caching)
# This layer only rebuilds when requirements.txt changes
COPY requirements.txt .

# Install PyTorch with CUDA 12.4 support
RUN pip3 install --no-cache-dir \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124

# Install application dependencies
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy config directory (contains macros.json)
# This should come after pip installs for better caching
COPY config ./config

# Copy application code last (changes most frequently)
COPY dragon_gpu_server.py .

# Create a non-root user for security
RUN useradd -m -u 1000 dragon && \
    chown -R dragon:dragon /app

# Switch to non-root user
USER dragon

# Health check - verifies server is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python3 -c "import requests; requests.get('http://localhost:5005/', timeout=5)" || exit 1

# Expose the port
EXPOSE 5005

# Use exec form for better signal handling
CMD ["python3", "-u", "dragon_gpu_server.py"]