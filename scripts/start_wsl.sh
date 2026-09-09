#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [ "$(detect_platform)" != "wsl" ]; then
    echo -e "${YELLOW}start_wsl.sh is intended for WSL2. Falling back to the local server path.${NC}"
fi

exec "$SCRIPT_DIR/start_server.sh" "$@"

