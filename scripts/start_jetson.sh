#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
project_root

MODEL="llama3.2-vision:11b"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "--model requires a non-empty value" >&2
                exit 2
            fi
            MODEL="$2"
            FORWARD_ARGS+=( "$1" "$2" )
            shift 2
            ;;
        *)
            FORWARD_ARGS+=( "$1" )
            shift
            ;;
    esac
done

print_header "Live VLM WebUI Jetson Launcher"
echo ""

PLATFORM="$(detect_platform)"
if [ "$PLATFORM" != "jetson-orin" ] && [ "$PLATFORM" != "jetson-thor" ]; then
    echo -e "${RED}This launcher is intended for Jetson Orin or Jetson Thor.${NC}"
    echo -e "${YELLOW}Use ./scripts/start_wsl.sh on Windows/WSL.${NC}"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker is not installed on this Jetson.${NC}"
    echo -e "${YELLOW}Install Docker and the NVIDIA container runtime first.${NC}"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Docker is installed but the daemon is not reachable.${NC}"
    echo -e "${YELLOW}Start it with: sudo systemctl enable --now docker${NC}"
    exit 1
fi

if ! docker info 2>/dev/null | grep -qi "nvidia"; then
    echo -e "${YELLOW}Docker does not report the NVIDIA runtime.${NC}"
    echo -e "${YELLOW}If containers fail to see the GPU, run:${NC}"
    echo "  sudo nvidia-ctk runtime configure --runtime=docker"
    echo "  sudo systemctl restart docker"
    echo ""
fi

if [ ! -S /run/jtop.sock ]; then
    echo -e "${YELLOW}jtop socket not found. GPU monitoring inside the container will be limited.${NC}"
    echo -e "${YELLOW}Install jetson-stats if you want full telemetry.${NC}"
    echo ""
fi

export LIVE_VLM_PROCESS_EVERY="${LIVE_VLM_PROCESS_EVERY:-45}"
export NANOOWL_DEVICE="${NANOOWL_DEVICE:-cuda}"

if [[ " ${FORWARD_ARGS[*]} " != *" --model "* ]]; then
    FORWARD_ARGS+=( --model "$MODEL" )
fi

echo -e "${GREEN}Building this checkout and starting the Jetson stack.${NC}"
echo -e "${YELLOW}The first run downloads image layers and the model and can take a while.${NC}"
echo ""

exec "$SCRIPT_DIR/start_docker_compose.sh" --backend ollama --build --pull-model "${FORWARD_ARGS[@]}"
