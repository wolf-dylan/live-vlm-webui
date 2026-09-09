#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
project_root

BACKEND="ollama"
MODEL=""
PROFILE=""
DETACH=true
PULL_MODEL=false
NON_INTERACTIVE=false
STOP_EXISTING=true
BUILD_IMAGES=false
POSITIONAL_ARGS=()

if [ ! -t 0 ] || [ ! -t 1 ]; then
    NON_INTERACTIVE=true
fi

show_usage() {
    cat <<'EOF'
Usage: ./scripts/start_docker_compose.sh [options]

Options:
  --backend BACKEND       Backend to launch: ollama or nim (default: ollama)
  --model MODEL           Model to pull/configure after startup
  --profile PROFILE       Override auto-selected compose profile
  --foreground            Run `docker compose up` in the foreground
  --pull-model            Pull the Ollama model after startup
  --no-pull-model         Do not pull the Ollama model after startup
  --non-interactive       Fail instead of prompting
  --no-stop-existing      Leave existing compose stack running
  --build                 Build the selected WebUI image from this checkout
  -h, --help              Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "--backend requires a non-empty value" >&2
                exit 2
            fi
            BACKEND="$2"
            shift 2
            ;;
        --model)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "--model requires a non-empty value" >&2
                exit 2
            fi
            MODEL="$2"
            shift 2
            ;;
        --profile)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "--profile requires a non-empty value" >&2
                exit 2
            fi
            PROFILE="$2"
            shift 2
            ;;
        --foreground)
            DETACH=false
            shift
            ;;
        --pull-model)
            PULL_MODEL=true
            shift
            ;;
        --no-pull-model)
            PULL_MODEL=false
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --no-stop-existing)
            STOP_EXISTING=false
            shift
            ;;
        --build)
            BUILD_IMAGES=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=( "$1" )
            shift
            ;;
    esac
done

if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
    if [ "${POSITIONAL_ARGS[0]}" = "ollama" ] || [ "${POSITIONAL_ARGS[0]}" = "nim" ]; then
        BACKEND="${POSITIONAL_ARGS[0]}"
        if [ "${#POSITIONAL_ARGS[@]}" -gt 1 ] && [ -z "$MODEL" ]; then
            MODEL="${POSITIONAL_ARGS[1]}"
        fi
    else
        echo "Unknown positional arguments: ${POSITIONAL_ARGS[*]}"
        show_usage
        exit 1
    fi
fi

if [ -z "$MODEL" ] && [ "$BACKEND" = "ollama" ]; then
    MODEL="llama3.2-vision:11b"
fi

if [ "$BACKEND" = "ollama" ]; then
    # Configure the WebUI deterministically even when the Ollama volume is
    # empty.  Without these values server auto-detection sees no models during
    # first boot and incorrectly falls back to the NVIDIA cloud endpoint.
    export LIVE_VLM_API_BASE="${LIVE_VLM_API_BASE:-http://localhost:11434/v1}"
    export LIVE_VLM_DEFAULT_MODEL="${LIVE_VLM_DEFAULT_MODEL:-$MODEL}"
fi

if [ "${LIVE_VLM_PULL_MODEL:-0}" = "1" ]; then
    PULL_MODEL=true
fi

PLATFORM="$(detect_platform)"
if [ -z "$PROFILE" ]; then
    PROFILE="$(default_compose_profile "$BACKEND" "$PLATFORM")"
fi

if [ -z "$PROFILE" ]; then
    echo -e "${RED}Unsupported backend/platform combination.${NC}"
    exit 1
fi

ensure_docker
COMPOSE_CMD="$(docker_compose_cmd)"

print_header "Live VLM WebUI Compose Launcher"
echo ""
echo -e "${GREEN}Platform:${NC} $PLATFORM"
echo -e "${GREEN}Backend:${NC}  $BACKEND"
echo -e "${GREEN}Profile:${NC}  $PROFILE"
echo -e "${GREEN}Compose:${NC}  $COMPOSE_FILE"
if [ -n "$MODEL" ]; then
    echo -e "${GREEN}Model:${NC}    $MODEL"
fi
echo ""

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}Compose file not found: $COMPOSE_FILE${NC}"
    exit 1
fi

if [ "$BACKEND" = "nim" ] && [ -z "${NGC_API_KEY:-}" ]; then
    echo -e "${RED}NGC_API_KEY is required for the NIM backend.${NC}"
    exit 1
fi

existing_services="$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --services --filter status=running 2>/dev/null || true)"
if [ -n "$existing_services" ] && [ "$STOP_EXISTING" = true ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${YELLOW}Stopping existing compose services before restart.${NC}"
        $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans
    else
        echo -e "${YELLOW}Existing compose services are already running:${NC}"
        echo "$existing_services"
        read -r -p "Restart them now? [Y/n] " reply
        if [[ ! "$reply" =~ ^[Nn]$ ]]; then
            $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans
        else
            echo -e "${RED}Refusing to start a second stack on the same ports.${NC}"
            exit 1
        fi
    fi
fi

if [ -n "$existing_services" ] && [ "$STOP_EXISTING" = false ] && [ "$NON_INTERACTIVE" = true ]; then
    echo -e "${RED}Compose services are already running and --no-stop-existing was set.${NC}"
    exit 1
fi

export COMPOSE_PROFILES="$PROFILE"
export PYTHONUNBUFFERED=1

if [ "$PLATFORM" = "jetson-orin" ] || [ "$PLATFORM" = "jetson-thor" ]; then
    export LIVE_VLM_PROCESS_EVERY="${LIVE_VLM_PROCESS_EVERY:-45}"
    export NANOOWL_DEVICE="${NANOOWL_DEVICE:-cuda}"
    export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
    export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
fi

UP_ARGS=( -f "$COMPOSE_FILE" --profile "$PROFILE" up )
if [ "$DETACH" = true ]; then
    UP_ARGS+=( -d )
fi
if [ "$BUILD_IMAGES" = true ]; then
    UP_ARGS+=( --build )
fi

echo -e "${BLUE}Starting services...${NC}"
if [ "$COMPOSE_CMD" = "docker compose" ]; then
    docker compose "${UP_ARGS[@]}"
else
    docker-compose "${UP_ARGS[@]}"
fi

if [ "$BACKEND" = "ollama" ] && [ "$PULL_MODEL" = true ] && [ -n "$MODEL" ]; then
    echo ""
    echo -e "${BLUE}Waiting for Ollama to become ready...${NC}"
    for attempt in $(seq 1 30); do
        if docker exec ollama ollama list >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if docker exec ollama ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$MODEL"; then
        echo -e "${GREEN}Model already present: $MODEL${NC}"
    else
        echo -e "${BLUE}Pulling Ollama model: $MODEL${NC}"
        docker exec ollama ollama pull "$MODEL"
    fi
fi

if [ "$DETACH" = true ]; then
    echo ""
    echo -e "${BLUE}Waiting for the WebUI health check...${NC}"
    webui_ready=false
    for attempt in $(seq 1 45); do
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' live-vlm-webui 2>/dev/null || true)"
        case "$health" in
            healthy|running)
                webui_ready=true
                break
                ;;
            unhealthy|exited|dead)
                echo -e "${RED}WebUI container entered state: $health${NC}"
                docker logs --tail 80 live-vlm-webui >&2 || true
                exit 1
                ;;
        esac
        sleep 2
    done
    if [ "$webui_ready" != true ]; then
        echo -e "${RED}Timed out waiting for the WebUI container to become ready.${NC}"
        docker logs --tail 80 live-vlm-webui >&2 || true
        exit 1
    fi
fi

HOST_ADDR="$(local_access_host)"
echo ""
print_header "Access Information"
echo ""
echo -e "${GREEN}Web UI:${NC} https://${HOST_ADDR}:8090"
case "$BACKEND" in
    ollama)
        echo -e "${GREEN}Ollama API:${NC} http://${HOST_ADDR}:11434/v1"
        if [ "$PULL_MODEL" = false ] && [ -n "$MODEL" ]; then
            echo -e "${YELLOW}Model pull skipped:${NC} docker exec ollama ollama pull $MODEL"
        fi
        ;;
    nim)
        echo -e "${GREEN}NIM API:${NC} http://${HOST_ADDR}:8000/v1"
        ;;
esac
echo ""
echo -e "${BLUE}Stop:${NC} ./scripts/stop_docker_compose.sh"
echo -e "${BLUE}Logs:${NC} $COMPOSE_CMD -f \"$COMPOSE_FILE\" logs -f"
echo ""
