#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "stop_container.sh is deprecated."
echo "Routing to the compose-based stop script."
exec "$SCRIPT_DIR/stop_docker_compose.sh" "$@"
