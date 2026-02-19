#!/bin/bash
# Install Python dependencies and pre-download the sentiment model.
# This runs during rootfs prep (chroot has internet access).
# At VM runtime, the model is already available locally — no internet needed.
set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "[setup] Installing transformers, flask, torch, requests..."
pip3 install --break-system-packages \
    transformers \
    flask \
    requests \
    torch \
    --index-url https://download.pytorch.org/whl/cpu

echo "[setup] Pre-downloading distilbert sentiment model..."
python3 - <<'PYTHON'
from transformers import AutoModelForSequenceClassification, AutoTokenizer
import os

model_name = "distilbert-base-uncased-finetuned-sst-2-english"
save_path = "/app/model_cache/sentiment_model"

os.makedirs(save_path, exist_ok=True)

print(f"  Downloading {model_name} to {save_path}...")
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForSequenceClassification.from_pretrained(model_name)

tokenizer.save_pretrained(save_path)
model.save_pretrained(save_path)
print(f"  Model saved to {save_path}")
PYTHON

echo "[setup] Setup complete. Model available at /app/model_cache/sentiment_model"
