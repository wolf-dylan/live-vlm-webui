#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Profile the WebUI's GPU work (NanoOWL detector) using the MODERN Nsight tools
# that ship with the Windows installs (which support Blackwell / RTX 5080).
# The Ubuntu-apt Nsight packages are far too old (2021.x) for a 5080 -- do not
# use them.
#
# Usage (from the live-vlm-webui folder, no venv needs to be pre-activated):
#   ./scripts/profile_gpu.sh version          # print tool versions
#   ./scripts/profile_gpu.sh sys              # Nsight Systems timeline (fast)
#   ./scripts/profile_gpu.sh compute          # Nsight Compute kernel metrics (slow)
#
# Extra args after the tool are passed to profile_detector.py, e.g.:
#   ./scripts/profile_gpu.sh sys --iters 20 --query "a person, a badge"
#
# Reports are written next to this repo:
#   detector_timeline.nsys-rep   (open in Nsight Systems on Windows)
#   detector_report.ncu-rep      (open in Nsight Compute on Windows)
#
# Platforms:
#   * x86 WSL dev box  -> uses the MODERN Nsight bundled with the Windows install
#     (the apt/native Linux ncu there is 2021.x and too old for Blackwell/RTX 50xx).
#   * Jetson (Orin/Thor) or any aarch64 board -> uses the NATIVE JetPack ncu/nsys
#     already on PATH (the x86 Windows binaries can't run on ARM anyway).
#
# Jetson note: Nsight Compute needs access to GPU performance counters. If you
# hit ERR_NVGPUCTRPERM, run the compute profile with sudo, e.g.:
#   sudo -E env "PATH=$PATH" ./scripts/profile_gpu.sh compute
#
# Overrides (any platform):
#   NCU_BIN=/path/to/ncu        use a specific ncu
#   NSYS_BIN=/path/to/nsys      use a specific nsys
#   NSIGHT_WIN_ROOT="/mnt/c/Program Files/NVIDIA Corporation"   Windows install root

set -e
cd "$(cd "$(dirname "$0")" && pwd)/.."

# ---------------------------------------------------------------------------
# Tool selection
# ---------------------------------------------------------------------------
# Jetson / aarch64 boards (and plain Linux hosts with a modern Nsight on PATH)
# use the NATIVE ncu/nsys. An x86 WSL dev box instead uses the MODERN Nsight
# bundled with the Windows install, because the apt/native Linux ncu on that box
# is 2021.x and too old for Blackwell (RTX 50xx). Explicit NCU_BIN / NSYS_BIN
# always win.
ARCH="$(uname -m)"
IS_JETSON=0
[ -f /etc/nv_tegra_release ] && IS_JETSON=1

# Windows Nsight install root (WSL only). Auto-detect the newest installed
# version folder so this keeps working across Nsight updates.
WIN_NSIGHT_ROOT="${NSIGHT_WIN_ROOT:-/mnt/c/Program Files/NVIDIA Corporation}"

latest_dir() {  # $1 = path prefix; echoes newest matching dir by version (or "")
    ls -d "$1"* 2>/dev/null | sort -V | tail -1
}

NCU_WIN="$(latest_dir "$WIN_NSIGHT_ROOT/Nsight Compute ")"
NSYS_WIN="$(latest_dir "$WIN_NSIGHT_ROOT/Nsight Systems ")"
NCU_SRC="${NCU_SRC:-$NCU_WIN/target/linux-desktop-glibc_2_11_3-x64}"
NSYS_SRC="${NSYS_SRC:-$NSYS_WIN/target-linux-x64}"

# Use the native (PATH) tools on Jetson/aarch64, or when there is no Windows
# Nsight install to stage from (a plain Linux host).
USE_NATIVE=0
if [ "$IS_JETSON" = "1" ] || [ "$ARCH" = "aarch64" ]; then
    USE_NATIVE=1
elif [ ! -d "$NCU_WIN" ] && [ ! -d "$NSYS_WIN" ]; then
    USE_NATIVE=1
fi

# nsys/ncu inject libraries via LD_PRELOAD, which is SPACE-separated, so they
# cannot run from "C:\Program Files\..." (spaces break the preload). Stage the
# Linux target folders once into a space-free path on the WSL filesystem.
STAGE="$HOME/.cache/nsight"
# Keep the ORIGINAL leaf directory names -- nsys/ncu locate their support files
# by their own folder name (e.g. nsys requires '.../target-linux-x64/nsys').
NCU_DIR="$STAGE/linux-desktop-glibc_2_11_3-x64"
NSYS_DIR="$STAGE/target-linux-x64"
# Nsight Compute needs its section/rule files; they live next to the install
# ('.../Nsight Compute X/sections'). Stage them to a space-free path too.
NCU_SECTIONS_SRC="$NCU_SRC/../../sections"
NCU_SECTIONS_DIR="$STAGE/sections"

stage_tool() {  # $1=src dir  $2=dest dir  $3=binary name
    if [ ! -x "$2/$3" ] && [ -d "$1" ]; then
        echo "Staging $3 to $2 (first run, copying ~hundreds of MB)..."
        mkdir -p "$2"
        cp -r "$1"/. "$2"/
    fi
    # nsys refuses to run from inside target-linux-x64; it must be invoked via a
    # symlink that points at target-linux-x64/nsys.
    if [ "$3" = "nsys" ]; then
        ln -sf "$2/nsys" "$STAGE/nsys"
    fi
    # ncu needs its section/rule files staged alongside (space-free path).
    if [ "$3" = "ncu" ] && [ ! -d "$NCU_SECTIONS_DIR" ] && [ -d "$NCU_SECTIONS_SRC" ]; then
        echo "Staging ncu sections to $NCU_SECTIONS_DIR..."
        mkdir -p "$NCU_SECTIONS_DIR"
        cp -r "$NCU_SECTIONS_SRC"/. "$NCU_SECTIONS_DIR"/
    fi
}

# Resolvers populate NCU / NSYS (binary paths) and NCU_SECTION_ARGS (extra ncu
# flags). Only the Windows-staged ncu needs an explicit --section-folder; native
# installs ship their own sections.
NCU=""
NSYS=""
NCU_SECTION_ARGS=()

ensure_nsys() {
    if [ -n "${NSYS_BIN:-}" ]; then NSYS="$NSYS_BIN"; return; fi
    if [ "$USE_NATIVE" = "1" ]; then
        NSYS="$(command -v nsys || true)"
        if [ -z "$NSYS" ]; then
            echo "❌ nsys not found on PATH."
            echo "   Jetson/JetPack: sudo apt-get install nsight-systems  (or set NSYS_BIN=/path/to/nsys)"
            exit 1
        fi
        return
    fi
    if [ ! -d "$NSYS_SRC" ]; then
        echo "❌ Nsight Systems Linux target not found at: $NSYS_SRC"
        echo "   Set NSYS_BIN=/path/to/nsys or NSIGHT_WIN_ROOT to your install."
        exit 1
    fi
    stage_tool "$NSYS_SRC" "$NSYS_DIR" nsys
    NSYS="$STAGE/nsys"
}

ensure_ncu() {
    if [ -n "${NCU_BIN:-}" ]; then NCU="$NCU_BIN"; NCU_SECTION_ARGS=(); return; fi
    if [ "$USE_NATIVE" = "1" ]; then
        NCU="$(command -v ncu || true)"
        if [ -z "$NCU" ]; then
            echo "❌ ncu not found on PATH."
            echo "   Jetson/JetPack: sudo apt-get install nsight-compute  (or set NCU_BIN=/path/to/ncu)"
            exit 1
        fi
        NCU_SECTION_ARGS=()
        return
    fi
    if [ ! -d "$NCU_SRC" ]; then
        echo "❌ Nsight Compute Linux target not found at: $NCU_SRC"
        echo "   Set NCU_BIN=/path/to/ncu or NSIGHT_WIN_ROOT to your install."
        exit 1
    fi
    stage_tool "$NCU_SRC" "$NCU_DIR" ncu
    NCU="$NCU_DIR/ncu"
    NCU_SECTION_ARGS=(--section-folder "$NCU_SECTIONS_DIR")
}

# Prefer the project venv python (has torch cu128 + nanoowl).
if [ -x ".venv/bin/python" ]; then
    PY=".venv/bin/python"
else
    PY="python3"
fi

TOOL="${1:-sys}"
shift || true

case "$TOOL" in
    version)
        ensure_nsys
        ensure_ncu
        "$NSYS" --version
        echo "---"
        "$NCU" --version
        ;;
    sys)
        ensure_nsys
        echo "▶ Nsight Systems timeline -> detector_timeline.nsys-rep"
        "$NSYS" profile --force-overwrite true -o detector_timeline \
            "$PY" scripts/profile_detector.py "$@"
        ;;
    compute)
        ensure_ncu
        echo "▶ Nsight Compute kernel metrics -> detector_report.ncu-rep"
        echo "  (replays kernels; keep --launch-count small)"
        "$NCU" --set basic "${NCU_SECTION_ARGS[@]}" \
            --launch-skip 20 --launch-count 40 -f -o detector_report \
            "$PY" scripts/profile_detector.py --iters 5 --warmup 2 "$@"
        ;;
    *)
        echo "usage: $0 {version|sys|compute} [extra profile_detector.py args]"
        exit 1
        ;;
esac
