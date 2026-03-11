FROM ubuntu:24.04

# Prevent interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Allow pip to install globally (Fixes PEP 668 "externally managed environment" errors)
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# 1. Install System Dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    git \
    wget \
    gnupg2 \
    clinfo \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# 2. Add Intel Graphics Repository (Noble / Unified)
RUN wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --yes --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" | \
    tee /etc/apt/sources.list.d/intel-gpu-noble.list

# 3. Install Intel Client GPU Drivers (Arc Support)
RUN apt-get update && apt-get install -y \
    libze-intel-gpu1 \
    libze1 \
    intel-opencl-icd \
    clinfo \
    intel-gsc \
    intel-media-va-driver-non-free \
    libmfx-gen1 \
    libvpl2 \
    && rm -rf /var/lib/apt/lists/*

# 4. Set up Workspace
WORKDIR /app

# 5. Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git

# 6. Install Python Dependencies
WORKDIR /app/ComfyUI

# Install PyTorch with XPU Support (Pre-release for latest Arc fixes)
RUN pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/xpu

# Install ComfyUI Requirements AND GitPython (Required for ComfyUI-Manager)
RUN pip3 install -r requirements.txt GitPython

# 7. Expose Port
EXPOSE 8188

# 8. Start ComfyUI
# (Arguments are usually overridden by docker-compose, but this is a safe default)
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]