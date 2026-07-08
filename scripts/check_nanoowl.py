#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Report NanoOWL detector availability and GPU status for start_server.sh.

Prints one of:
  OK GPU <device name>
  OK CPU
  MISSING <reason>

NanoOWL is optional, so any import failure is reported as MISSING rather than
raising, letting the server start without object detection.
"""
try:
    import torch
    from nanoowl.owl_predictor import OwlPredictor  # noqa: F401

    if torch.cuda.is_available():
        print(f"OK GPU {torch.cuda.get_device_name(0)}")
    else:
        print("OK CPU")
except Exception as exc:  # nanoowl / torch are optional
    print(f"MISSING {exc}")
