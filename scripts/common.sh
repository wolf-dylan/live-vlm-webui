#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

project_root() {
    cd "$PROJECT_ROOT" || exit 1
}

print_header() {
    local title="$1"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ${title}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

is_wsl() {
    grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null
}

detect_platform() {
    local arch l4t_release
    arch="$(uname -m)"

    if [ -f /etc/nv_tegra_release ]; then
        # L4T R38+ identifies Jetson Thor.  /etc/nv_tegra_release normally
        # contains a release number, not the product name, so looking for the
        # literal word "thor" misclassifies production Thor images as Orin.
        l4t_release="$(sed -n 's/.*R\([0-9][0-9]*\).*/\1/p' /etc/nv_tegra_release | head -1)"
        if [ -n "$l4t_release" ] && [ "$l4t_release" -ge 38 ]; then
            echo "jetson-thor"
            return
        fi
        echo "jetson-orin"
        return
    fi

    if is_wsl; then
        echo "wsl"
        return
    fi

    case "$arch" in
        x86_64)
            echo "x86"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

default_compose_profile() {
    local backend="$1"
    local platform="$2"

    case "$backend" in
        ollama)
            case "$platform" in
                jetson-orin) echo "ollama-jetson-orin" ;;
                jetson-thor) echo "ollama-jetson-thor" ;;
                *) echo "ollama" ;;
            esac
            ;;
        nim)
            case "$platform" in
                jetson-orin) echo "nim-jetson-orin" ;;
                jetson-thor) echo "nim-jetson-thor" ;;
                *) echo "nim" ;;
            esac
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        return 0
    fi
    if has_command docker-compose; then
        echo "docker-compose"
        return 0
    fi
    return 1
}

ensure_docker() {
    if ! has_command docker; then
        echo -e "${RED}Docker is required but not installed.${NC}"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Docker daemon is not running or is not reachable.${NC}"
        return 1
    fi

    if ! docker_compose_cmd >/dev/null; then
        echo -e "${RED}Docker Compose is required but not available.${NC}"
        return 1
    fi
}

local_access_host() {
    local platform
    platform="$(detect_platform)"
    if [ "$platform" = "jetson-orin" ] || [ "$platform" = "jetson-thor" ]; then
        hostname -I 2>/dev/null | awk '{print $1}'
        return
    fi
    echo "localhost"
}
