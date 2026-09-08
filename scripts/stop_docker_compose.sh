#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
project_root

REMOVE_VOLUMES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./scripts/stop_docker_compose.sh [--volumes]
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

ensure_docker
COMPOSE_CMD="$(docker_compose_cmd)"

print_header "Stop Live VLM WebUI Compose Stack"
echo ""

DOWN_ARGS=( -f "$COMPOSE_FILE" down --remove-orphans )
if [ "$REMOVE_VOLUMES" = true ]; then
    DOWN_ARGS+=( --volumes )
fi

if [ "$COMPOSE_CMD" = "docker compose" ]; then
    docker compose "${DOWN_ARGS[@]}"
else
    docker-compose "${DOWN_ARGS[@]}"
fi

echo -e "${GREEN}Compose stack stopped.${NC}"

