#!/bin/bash
# Install PyTorch CPU-only build (~200MB, much smaller than CUDA build)
set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "[setup] Installing PyTorch (CPU-only)..."
pip3 install --break-system-packages \
    torch \
    --index-url https://download.pytorch.org/whl/cpu

echo "[setup] PyTorch installed successfully"
python3 -c "import torch; print(f'  torch version: {torch.__version__}')"
