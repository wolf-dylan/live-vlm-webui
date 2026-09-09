#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "jetson_quickstart.sh is deprecated."
echo "Routing to the supported Jetson launcher."
exec "$SCRIPT_DIR/start_jetson.sh" "$@"
