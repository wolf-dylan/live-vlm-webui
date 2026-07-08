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

# ==============================================================================
# Live VLM WebUI - Jetson One-Shot Quick Start (Docker)
# ==============================================================================
# Brings up the FULL stack on a fresh Jetson (Orin / Thor) with a single command:
#   1. Verifies this is a Jetson board
#   2. Ensures Docker is installed and running (installs it if missing)
#   3. Ensures the NVIDIA container runtime is configured (GPU in containers)
#   4. Starts Ollama + Live VLM WebUI via docker compose (correct Jetson profile)
#   5. Pulls a vision model so the app works immediately
#   6. Prints the URL to open
#
# Usage:
#   ./scripts/jetson_quickstart.sh                 # default model
#   ./scripts/jetson_quickstart.sh MODEL           # custom Ollama vision model
#
# Examples:
#   ./scripts/jetson_quickstart.sh
#   ./scripts/jetson_quickstart.sh qwen2.5vl:3b
# ==============================================================================

set -e

# --- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default vision model (override by passing an argument).
MODEL="${1:-llama3.2-vision:11b}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Live VLM WebUI - Jetson Quick Start${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ------------------------------------------------------------------ 1. Jetson?
if [ ! -f /etc/nv_tegra_release ]; then
    echo -e "${YELLOW}⚠️  This does not look like a Jetson board (/etc/nv_tegra_release not found).${NC}"
    echo -e "    This script is meant for Jetson Orin / Thor."
    echo -e "    On PC / DGX use: ${GREEN}./scripts/start_docker_compose.sh ollama $MODEL${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
else
    echo -e "${GREEN}✅ Jetson detected:${NC} $(head -1 /etc/nv_tegra_release)"
fi
echo ""

# ------------------------------------------------------------------ 2. Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}📦 Docker not found. Installing...${NC}"
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    echo -e "${YELLOW}⚠️  Added '$USER' to the docker group.${NC}"
    echo -e "    You may need to log out/in (or run 'newgrp docker') for it to take effect."
else
    echo -e "${GREEN}✅ Docker installed:${NC} $(docker --version)"
fi

# Make sure the Docker daemon is running.
if ! sudo docker info &> /dev/null; then
    echo -e "${YELLOW}🔧 Starting Docker daemon...${NC}"
    sudo systemctl enable --now docker || true
fi
echo ""

# ------------------------------------------------------- 3. NVIDIA container runtime
# On JetPack this is usually preinstalled, but make sure Docker knows about it so
# the Ollama container can use the GPU.
if ! sudo docker info 2>/dev/null | grep -qi 'nvidia'; then
    echo -e "${YELLOW}🔧 Configuring NVIDIA container runtime for Docker...${NC}"
    if command -v nvidia-ctk &> /dev/null; then
        sudo nvidia-ctk runtime configure --runtime=docker || true
        sudo systemctl restart docker || true
        echo -e "${GREEN}✅ NVIDIA runtime configured${NC}"
    else
        echo -e "${YELLOW}⚠️  nvidia-ctk not found. On JetPack the NVIDIA runtime is normally${NC}"
        echo -e "    preinstalled. If GPU access fails, install 'nvidia-container-toolkit'."
    fi
else
    echo -e "${GREEN}✅ NVIDIA container runtime available${NC}"
fi
echo ""

# ------------------------------------------------------------------ 4-6. Launch
# Delegate the heavy lifting to the platform-aware compose launcher, which:
#   - detects jetson-orin / jetson-thor and picks the right profile
#   - starts Ollama + Live VLM WebUI
#   - pulls the model into the Ollama container
#   - prints access info
echo -e "${BLUE}🚀 Starting the stack (Ollama + Live VLM WebUI) with model: ${GREEN}$MODEL${NC}"
echo ""
exec "$SCRIPT_DIR/start_docker_compose.sh" ollama "$MODEL"
