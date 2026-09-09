#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

# Start Live VLM WebUI Server with HTTPS

# Get script directory and navigate to project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
project_root

# Detect Jetson and recommend Docker
if [ -f /etc/nv_tegra_release ]; then
    echo "⚠️  Jetson platform detected!"
    echo ""
    echo "📦 We STRONGLY recommend using Docker for Jetson:"
    echo "   ./scripts/start_jetson.sh"
    echo ""
    echo "Why Docker?"
    echo "  ✅ No system package dependencies"
    echo "  ✅ Works out-of-the-box"
    echo "  ✅ Production-ready"
    echo "  ✅ Isolated from JetPack"
    echo ""
    echo "Local Python on Jetson requires:"
    echo "  • sudo apt install python3-venv (or python3.10-venv)"
    echo "  • pip upgrade to support modern packaging"
    echo "  • May conflict with JetPack packages"
    echo ""
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "Non-interactive shell detected; refusing local Jetson startup."
        echo "Run: ./scripts/start_jetson.sh"
        exit 1
    else
        read -p "Continue with local Python anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "👍 Good choice! Run: ./scripts/start_jetson.sh"
            exit 0
        fi
    fi
    echo "⚠️  Proceeding with local Python setup..."
    echo ""
fi

# Detect and activate virtual environment if needed
DETECTED_VENV=""
if [ -z "${VIRTUAL_ENV:-}" ] && [ -z "${CONDA_DEFAULT_ENV:-}" ]; then
    # Check for .venv (preferred)
    if [ -d ".venv" ]; then
        echo "Activating .venv virtual environment..."
        source .venv/bin/activate
        DETECTED_VENV=".venv"
        echo ""
    # Check for venv (alternative)
    elif [ -d "venv" ]; then
        echo "Activating venv virtual environment..."
        source venv/bin/activate
        DETECTED_VENV="venv"
        echo ""
    else
        echo "⚠️  No virtual environment detected!"
        echo "Please create one first:"
        echo "  python3 -m venv .venv"
        echo "  source .venv/bin/activate"
        echo "  pip install -e ."
        echo ""
        echo "Or activate your conda environment:"
        echo "  conda activate live-vlm-webui"
        exit 1
    fi
fi

# Use venv/conda python explicitly so we don't pick up system python
PYTHON="python"
if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
    PYTHON="${VIRTUAL_ENV}/bin/python"
elif [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python3" ]; then
    PYTHON="${VIRTUAL_ENV}/bin/python3"
elif [ -n "${CONDA_DEFAULT_ENV:-}" ] && command -v conda &>/dev/null; then
    PYTHON="$(conda run -n "${CONDA_DEFAULT_ENV}" which python 2>/dev/null)" || PYTHON="python"
fi

# If the currently-selected environment is missing the NanoOWL detector but the
# project's own ./.venv has it, prefer ./.venv. This prevents silently running
# with the wrong environment (e.g. a parent .venv that was left active), which
# would disable object detection ("boxes disabled"). Uses find_spec so we don't
# pay the cost of importing torch here.
_have_detector_deps() {
    "$1" -c "import importlib.util as u, sys; sys.exit(0 if u.find_spec('nanoowl') and u.find_spec('torch') else 1)" >/dev/null 2>&1
}
if [ -x ".venv/bin/python" ]; then
    if ! _have_detector_deps "$PYTHON" && _have_detector_deps ".venv/bin/python"; then
        echo "⚠️  Active environment lacks NanoOWL/torch; switching to project ./.venv..."
        if [ -n "${VIRTUAL_ENV:-}" ] && command -v deactivate >/dev/null 2>&1; then
            deactivate >/dev/null 2>&1 || true
        fi
        source .venv/bin/activate
        PYTHON="${VIRTUAL_ENV}/bin/python"
        DETECTED_VENV=".venv"
        echo "   Now using: $PYTHON"
        echo ""
    fi
fi

# Check if the package is installed in the current environment
if ! "$PYTHON" -c "import live_vlm_webui" 2>/dev/null; then
    echo "❌ Error: live_vlm_webui package not found!"
    echo ""

    # Detect which environment tool is available (prioritize venv over conda)
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        ENV_TYPE="virtual environment '$(basename "${VIRTUAL_ENV}")'"
    elif [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        ENV_TYPE="conda environment '${CONDA_DEFAULT_ENV}'"
    else
        ENV_TYPE="current environment"
    fi

    echo "You are in $ENV_TYPE but the package is not installed."
    echo ""
    echo "📋 To fix this, run ONE of the following:"
    echo ""

    # Show the venv that was actually detected/activated
    if [ -n "$DETECTED_VENV" ]; then
        echo "Option 1: Install in the detected virtual environment"
        echo "  source $DETECTED_VENV/bin/activate"
        echo "  pip install --upgrade pip setuptools wheel"
        echo "  pip install -e ."
        echo ""
    elif [ -d ".venv" ] || [ -d "venv" ]; then
        # Fallback if we're already in a venv but didn't detect it
        VENV_DIR=$([ -d ".venv" ] && echo ".venv" || echo "venv")
        echo "Option 1: Use the project's virtual environment"
        echo "  source $VENV_DIR/bin/activate"
        echo "  pip install --upgrade pip setuptools wheel"
        echo "  pip install -e ."
        echo ""
    fi

    # Conda option
    if command -v conda &> /dev/null; then
        echo "Option 2: Install in conda environment"
        echo "  conda activate ${CONDA_DEFAULT_ENV:-live-vlm-webui}"
        echo "  pip install -e ."
        echo ""
    fi

    # Generic pip install
    echo "Option 3: Install in current environment"
    echo "  pip install --upgrade pip setuptools wheel"
    echo "  pip install -e ."
    echo ""

    echo "💡 Tips:"
    echo "   - Upgrade pip first if you get 'setup.py not found' errors"
    echo "   - 'pip install -e .' installs in editable mode (changes take effect immediately)"
    echo ""
    exit 1
fi

# ------------------------------------------------------------------ NanoOWL
# Verify the optional NanoOWL object detector and make it use the GPU.
# NanoOWL is optional, so a failure here only prints a warning (never blocks
# the server). Default the detector to CUDA so it runs on the discrete GPU
# (e.g. RTX 5080) instead of falling back to a slow CPU path.
export NANOOWL_DEVICE="${NANOOWL_DEVICE:-cuda}"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

echo "Checking NanoOWL object detector..."
SKIP_NANOOWL_CHECK=false
for arg in "$@"; do
    case "$arg" in
        -h|--help|--version) SKIP_NANOOWL_CHECK=true ;;
    esac
done

if [ "$SKIP_NANOOWL_CHECK" = true ]; then
    NANOOWL_CHECK="MISSING check skipped for help/version"
elif command -v timeout >/dev/null 2>&1; then
    NANOOWL_CHECK="$(timeout "${NANOOWL_CHECK_TIMEOUT_SECONDS:-20}s" \
        "$PYTHON" "$SCRIPT_DIR/check_nanoowl.py" 2>&1 || true)"
    if [ -z "$NANOOWL_CHECK" ]; then
        NANOOWL_CHECK="DEFERRED cold-start check timed out"
    fi
else
    NANOOWL_CHECK="$("$PYTHON" "$SCRIPT_DIR/check_nanoowl.py" 2>&1 || true)"
fi

case "$NANOOWL_CHECK" in
  "OK GPU "*)
    echo "✅ NanoOWL ready on GPU: ${NANOOWL_CHECK#OK GPU } (NANOOWL_DEVICE=$NANOOWL_DEVICE)"
    ;;
  "OK CPU")
    echo "⚠️  NanoOWL loaded but no CUDA GPU detected — detection will be slow."
    echo "    Make sure you are using the venv with a CUDA build of torch."
    export NANOOWL_DEVICE="cpu"
    ;;
  "DEFERRED "*)
    echo "⚠️  NanoOWL GPU check timed out; availability will be retried when boxes are enabled."
    echo "    The first detection can take longer while CUDA and model weights warm up."
    ;;
  *)
    echo "⚠️  NanoOWL not available (object detection disabled): ${NANOOWL_CHECK#MISSING }"
    echo "    To enable it, use the venv that has nanoowl + a CUDA torch build,"
    echo "    e.g.: pip install -e ../nanoowl  (and torch/torchvision/transformers)"
    ;;
esac
echo ""

# Start server. The Python entry point owns port validation and TLS certificate
# generation so --port, --auto-port, --no-ssl, and custom certificate paths all
# behave exactly the same whether launched directly or through this script.
echo "Starting Live VLM WebUI server..."
echo "Auto-detecting local VLM services (Ollama, vLLM, SGLang)..."
echo "Will fall back to NVIDIA API Catalog if none found"
echo ""
echo "⚠️  Your browser will show a security warning (self-signed certificate)"
echo "    Click 'Advanced' → 'Proceed to localhost' (or 'Accept Risk')"
echo ""

# Run server with auto-detection (no --model or --api-base specified)
# To override, use: ./scripts/start_server.sh --model YOUR_MODEL --api-base YOUR_API
"$PYTHON" -m live_vlm_webui.server "$@"
