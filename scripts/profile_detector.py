#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""
NanoOWL detector profiling harness for Nsight Compute / Nsight Systems.

The Live VLM WebUI's own GPU work (inside the Python process) is the NanoOWL
open-vocabulary detector. The VLM text generation runs in a *separate* backend
(e.g. Ollama), so it is not visible to a profiler attached to this process.

This script loads the same NanoOwlDetector the server uses and runs a fixed
number of detection iterations on a test frame, giving a profiler a finite,
repeatable CUDA workload (instead of a long-running interactive server).

Usage (from the live-vlm-webui folder, with the project .venv active):
    python scripts/profile_detector.py --iters 20 --warmup 5
    python scripts/profile_detector.py --image path/to/frame.jpg --query "a person, a face"

Profile it with Nsight Compute (Linux/WSL). Keep the kernel count small:
    ncu --set basic --launch-count 40 -o detector_report \
        .venv/bin/python scripts/profile_detector.py --iters 5 --warmup 2

Or a timeline with Nsight Systems (much lighter, good for an overview):
    nsys profile -o detector_timeline .venv/bin/python scripts/profile_detector.py
"""
import argparse
import os
import sys
import time

# Make sure we can import the package when run from the repo root.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402


def build_image(path: str | None, width: int, height: int) -> Image.Image:
    if path:
        return Image.open(path).convert("RGB")
    # Deterministic synthetic frame so runs are comparable.
    rng = np.random.default_rng(0)
    arr = rng.integers(0, 255, size=(height, width, 3), dtype=np.uint8)
    return Image.fromarray(arr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Profile the NanoOWL detector.")
    parser.add_argument("--query", default="a person, a face, a hand",
                        help="Comma-separated detection labels.")
    parser.add_argument("--image", default=None, help="Optional test image path.")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--iters", type=int, default=20, help="Timed iterations.")
    parser.add_argument("--warmup", type=int, default=5,
                        help="Warmup iterations (excluded from timing / narrow profiling).")
    args = parser.parse_args()

    # Default the detector to the GPU (matches start_server.sh behaviour).
    os.environ.setdefault("NANOOWL_DEVICE", "cuda")

    from live_vlm_webui.detector_service import NanoOwlDetector

    det = NanoOwlDetector()
    status = det.get_status()
    if not status.get("available"):
        print(f"NanoOWL unavailable: {status.get('error')}", file=sys.stderr)
        return 1

    det.set_query(args.query)
    image = build_image(args.image, args.width, args.height)

    print(f"Device={os.environ['NANOOWL_DEVICE']} query={args.query!r} "
          f"image={image.width}x{image.height}")

    # Warmup (kernel autotuning, cache, cuDNN algo selection).
    for _ in range(args.warmup):
        det._detect_sync(image)

    try:
        import torch
        torch.cuda.synchronize()
    except Exception:
        pass

    start = time.perf_counter()
    for _ in range(args.iters):
        det._detect_sync(image)
    try:
        import torch
        torch.cuda.synchronize()
    except Exception:
        pass
    elapsed = time.perf_counter() - start

    per_iter = elapsed / max(args.iters, 1)
    print("\n===== DETECTOR PROFILE =====")
    print(f"Iterations: {args.iters}")
    print(f"Total time: {elapsed*1000:.1f} ms")
    print(f"Per inference: {per_iter*1000:.1f} ms  ({1.0/per_iter:.1f} inf/s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
