#!/usr/bin/env bash
# One-shot setup for Totem with MLX CUDA embeddings on Ubuntu 24.04 (Noble).
# Run once on a fresh machine, then use build-linux-cuda.sh to build.
#
# What this installs:
#   - Swift 6.3.2 (via swiftly)
#   - CUDA Toolkit 12.9
#   - OpenBLAS / LAPACK / LAPACKE
#   - cudnn-frontend v1.16.0 (header-only, to /usr/local/cudnn-frontend)
#   - huggingface_hub Python package (for model download)

set -euo pipefail

# ── Swift via swiftly ────────────────────────────────────────────────────────

if command -v swift &>/dev/null; then
    echo "==> Swift already installed: $(swift --version 2>&1 | head -1)"
else
    echo "==> Installing Swift 6.3.2 via swiftly..."
    curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
    tar -xzf swiftly-$(uname -m).tar.gz
    ./swiftly init --quiet --assume-yes
    source "$HOME/.local/share/swiftly/env.sh"
    swiftly install 6.3.2 --assume-yes
    rm -f swiftly-$(uname -m).tar.gz swiftly
fi

# ── CUDA Toolkit 12.9 ────────────────────────────────────────────────────────

if command -v nvcc &>/dev/null; then
    echo "==> CUDA already installed: $(nvcc --version | grep release)"
else
    echo "==> Adding NVIDIA CUDA 12.9 repository..."
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
    KEYRING_DEB="$(mktemp /tmp/cuda-keyring-XXXXXX.deb)"
    wget -q "$KEYRING_URL" -O "$KEYRING_DEB"
    sudo dpkg -i "$KEYRING_DEB"
    rm -f "$KEYRING_DEB"
    sudo apt-get update -q

    echo "==> Installing cuda-toolkit-12-9..."
    # Do NOT install libcudnn9-dev-cuda-12 — it conflicts with cuda-toolkit-12-9
    # which already provides cuDNN headers. The graph API comes from the
    # cudnn-frontend clone below.
    sudo apt-get install -y cuda-toolkit-12-9
fi

# ── BLAS / LAPACK ────────────────────────────────────────────────────────────

echo "==> Installing OpenBLAS / LAPACK..."
sudo apt-get install -y libopenblas-dev liblapack-dev liblapacke-dev gfortran

# ── cudnn-frontend v1.16.0 ───────────────────────────────────────────────────

if [[ -d /usr/local/cudnn-frontend ]]; then
    echo "==> /usr/local/cudnn-frontend already exists, skipping clone."
else
    echo "==> Cloning cudnn-frontend v1.16.0 to /usr/local/cudnn-frontend..."
    # Ubuntu's libcudnn-frontend-dev is v0.x; MLX requires the v1.x graph API.
    sudo git clone --depth 1 --branch v1.16.0 \
        https://github.com/NVIDIA/cudnn-frontend.git \
        /usr/local/cudnn-frontend
fi

# ── Frigate, as a sibling ────────────────────────────────────────────────────
# Package.swift takes Frigate by path (../Frigate), because Frigate itself carries a
# path dependency that a URL consumer cannot resolve. So the sibling has to exist here.
# Frigate's own manifest keeps everything macOS-only (VisionAX, its xcframeworks) inside
# `#if !os(Linux)`, which is why this box never needs ../VisionAX.

FRIGATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Frigate"
if [[ -d "$FRIGATE_DIR/.git" ]]; then
    echo "==> ../Frigate present, fast-forwarding..."
    git -C "$FRIGATE_DIR" pull --ff-only || echo "    (could not fast-forward; leaving the checkout as it is)"
else
    echo "==> Cloning Frigate beside this checkout (../Frigate)..."
    git clone --branch main https://github.com/rao-studios/Frigate.git "$FRIGATE_DIR"
fi

# ── Shell environment ────────────────────────────────────────────────────────

PROFILE="$HOME/.bashrc"
CUDA_PATH_LINE='export PATH=/usr/local/cuda/bin:$PATH'
CUDA_LIB_LINE='export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}'
SWIFTLY_LINE='source "$HOME/.local/share/swiftly/env.sh"'

add_line() { grep -qxF "$1" "$2" || echo "$1" >> "$2"; }
add_line "$CUDA_PATH_LINE"  "$PROFILE"
add_line "$CUDA_LIB_LINE"   "$PROFILE"
add_line "$SWIFTLY_LINE"    "$PROFILE"

export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}

# ── Python / huggingface_hub (model download) ─────────────────────────────────

echo "==> Installing huggingface_hub for model download..."
if ! command -v pip3 &>/dev/null; then
    sudo apt-get install -y python3-pip
fi
pip3 install --quiet huggingface_hub

# ── Verify ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Verifying installation..."
swift --version
nvcc --version | grep release
ls /usr/local/cuda/lib64/libcudart.so* &>/dev/null && echo "libcudart: OK" || echo "WARNING: libcudart not found"
ls /usr/local/cudnn-frontend/include/cudnn_frontend.h &>/dev/null && echo "cudnn-frontend: OK" || echo "WARNING: cudnn-frontend not found"
ls /usr/include/lapack.h &>/dev/null && echo "lapack.h: OK" || echo "WARNING: liblapacke-dev not found"

echo ""
echo "==> Setup complete."
echo ""
echo "Next steps:"
echo "  1. Download the embedding model (one-time, ~500 MB):"
echo "       python3 -m huggingface_hub download mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
echo ""
echo "  2. Copy .env.example to .env and add your Mistral API key (only needed for non-MLX builds):"
echo "       cp .env.example .env"
echo ""
echo "  3. Build:"
echo "       ./build-linux-cuda.sh"
echo ""
echo "  4. Run:"
echo "       .build/debug/totem --host 127.0.0.1 --port 8080 --use-mlx"
