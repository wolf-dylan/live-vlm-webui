#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
project_root

# Gemma is the reliable small-board default. Llama remains available through
# --model once the installed Ollama runtime supports its mllama architecture.
MODEL="gemma3:4b"
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

echo -e "${GREEN}Host Python:${NC} not used (Docker mode; no host venv or host pip required)"
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo -e "${YELLOW}This launcher was invoked as root.${NC}"
    echo "Any pip commands in the build run inside the Docker image, not on the Jetson host."
    echo "For rootless launches, add your login user to the docker group and re-login."
    echo ""
fi

# A forced client API disables Docker's normal API negotiation. Values copied
# from old workarounds (especially DOCKER_API_VERSION=1) break modern Compose.
if [ -n "${DOCKER_API_VERSION:-}" ]; then
    echo -e "${YELLOW}Ignoring forced DOCKER_API_VERSION=$DOCKER_API_VERSION; using API negotiation.${NC}"
    unset DOCKER_API_VERSION
fi

DOCKER_SERVICE_ENV="$(systemctl show docker.service --property=Environment --value 2>/dev/null || true)"
case " $DOCKER_SERVICE_ENV " in
    *" DOCKER_MIN_API_VERSION=1 "*|*" DOCKER_API_VERSION=1 "*)
        echo -e "${RED}Docker's systemd service has an invalid forced API version of 1.${NC}"
        echo "Remove that Environment= line with 'sudo systemctl edit docker', then run:"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl restart docker"
        exit 1
        ;;
esac

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

DOCKER_SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
DOCKER_SERVER_API="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
echo -e "${GREEN}Docker server:${NC} ${DOCKER_SERVER_VERSION:-unknown} (API ${DOCKER_SERVER_API:-unknown})"

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Docker Compose v2 is required for the Jetson launcher.${NC}"
    echo -e "${YELLOW}Install the docker-compose-plugin package; do not use legacy docker-compose v1.${NC}"
    exit 1
fi

case "$PLATFORM" in
    jetson-orin)
        # Official Ollama images cannot infer the JetPack generation from
        # inside a container. Without this they may start without usable CUDA.
        export JETSON_JETPACK="${JETSON_JETPACK:-6}"
        export OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
        export OLLAMA_RUNTIME="${OLLAMA_RUNTIME:-nvidia}"

        # NanoOWL is not a pure-Python dependency. Its CUDA/TensorRT base must
        # match the exact L4T release, so resolve NVIDIA's Jetson container
        # instead of baking a stale r36.x tag into this application.
        if [ -z "${JETSON_WEBUI_BASE_IMAGE:-}" ]; then
            if ! command -v autotag >/dev/null 2>&1; then
                echo -e "${RED}jetson-containers is required to select a JetPack-compatible NanoOWL image.${NC}"
                echo "Install it once, then rerun this launcher:"
                echo "  git clone https://github.com/dusty-nv/jetson-containers.git ~/jetson-containers"
                echo "  bash ~/jetson-containers/install.sh"
                exit 1
            fi
            JETSON_WEBUI_BASE_IMAGE="$(autotag nanoowl | tail -n 1)"
            if [ -z "$JETSON_WEBUI_BASE_IMAGE" ]; then
                echo -e "${RED}autotag could not resolve a NanoOWL image for this JetPack release.${NC}" >&2
                exit 1
            fi
            export JETSON_WEBUI_BASE_IMAGE
        fi
        export NANOOWL_IMAGE_ENCODER_ENGINE="${NANOOWL_IMAGE_ENCODER_ENGINE:-/opt/nanoowl/data/owl_image_encoder_patch32.engine}"
        ;;
    jetson-thor)
        # NVIDIA's SBSA image is built for JetPack 7 / L4T r38.x.
        export OLLAMA_IMAGE="${OLLAMA_IMAGE:-ghcr.io/nvidia-ai-iot/ollama:r38.2.arm64-sbsa-cu130-24.04}"
        export OLLAMA_RUNTIME="${OLLAMA_RUNTIME:-nvidia}"
        ;;
esac

if ! docker info 2>/dev/null | grep -qi "nvidia"; then
    echo -e "${RED}Docker does not report the NVIDIA runtime.${NC}"
    echo -e "${YELLOW}Configure it before starting this GPU application:${NC}"
    echo "  sudo nvidia-ctk runtime configure --runtime=docker"
    echo "  sudo systemctl restart docker"
    exit 1
fi

if [ ! -S /run/jtop.sock ]; then
    echo -e "${YELLOW}jtop telemetry socket is not running; attempting to enable it.${NC}"
    JTOP_BIN="$(command -v jtop 2>/dev/null || true)"
    if [ -z "$JTOP_BIN" ]; then
        echo -e "${RED}jetson-stats is not installed, so required Jetson telemetry is unavailable.${NC}"
        echo "Install it without modifying the system Python environment, then rerun this launcher:"
        echo "  sudo -v"
        echo "  curl -LsSf https://raw.githubusercontent.com/rbonghi/jetson_stats/master/scripts/install_jtop_torun_without_sudo.sh | bash"
        exit 1
    fi

    if systemctl cat jtop.service >/dev/null 2>&1; then
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            systemctl enable --now jtop.service
        else
            sudo systemctl enable --now jtop.service
        fi
    else
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            "$JTOP_BIN" --install-service
        else
            sudo "$JTOP_BIN" --install-service
        fi
    fi

    for attempt in $(seq 1 10); do
        [ -S /run/jtop.sock ] && break
        sleep 1
    done
fi

if [ ! -S /run/jtop.sock ]; then
    echo -e "${RED}jtop.service did not create /run/jtop.sock; WebUI telemetry cannot start.${NC}"
    echo "Check it with: sudo systemctl status jtop.service --no-pager"
    exit 1
fi
echo -e "${GREEN}Jetson telemetry:${NC} /run/jtop.sock ready"

export LIVE_VLM_PROCESS_EVERY="${LIVE_VLM_PROCESS_EVERY:-45}"
export NANOOWL_DEVICE="${NANOOWL_DEVICE:-cuda}"

if [[ " ${FORWARD_ARGS[*]} " != *" --model "* ]]; then
    FORWARD_ARGS+=( --model "$MODEL" )
fi

echo -e "${GREEN}Building this checkout and starting the Jetson stack.${NC}"
echo -e "${GREEN}Ollama image:${NC} $OLLAMA_IMAGE"
echo -e "${GREEN}Vision model:${NC} $MODEL"
if [ "$PLATFORM" = "jetson-orin" ]; then
    echo -e "${GREEN}NanoOWL base:${NC} $JETSON_WEBUI_BASE_IMAGE"
fi
echo -e "${YELLOW}The first run downloads image layers and Gemma and can take a while.${NC}"
echo ""

exec "$SCRIPT_DIR/start_docker_compose.sh" --backend ollama --build --pull-model "${FORWARD_ARGS[@]}"
