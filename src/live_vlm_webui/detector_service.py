# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
NanoOWL Detector Service

Dedicated open-vocabulary object detector based on NVIDIA NanoOWL (OWL-ViT +
TensorRT). Runs concurrently with the VLM text pipeline and emits normalized
bounding boxes for the UI overlay.

NanoOWL is optional: if it (or its dependencies such as TensorRT / torch2trt)
is not installed, the detector degrades gracefully to a no-op so the server
still runs on non-Jetson machines.
"""

import asyncio
import logging
import os
import re
import threading
import time
from typing import Any, Optional

from PIL import Image

logger = logging.getLogger(__name__)

# Optional import: NanoOWL is only available on properly provisioned Jetson
# (or CUDA) environments. Importing must never crash the server.
try:
    from nanoowl.owl_predictor import OwlPredictor  # type: ignore

    _NANOOWL_AVAILABLE = True
    _NANOOWL_IMPORT_ERROR: Optional[Exception] = None
except Exception as exc:  # pragma: no cover - environment dependent
    OwlPredictor = None  # type: ignore
    _NANOOWL_AVAILABLE = False
    _NANOOWL_IMPORT_ERROR = exc


class NanoOwlDetector:
    """Open-vocabulary detector wrapping a NanoOWL ``OwlPredictor``."""

    def __init__(
        self,
        model: str = "google/owlvit-base-patch32",
        image_encoder_engine: Optional[str] = None,
        threshold: float = 0.1,
    ):
        self.model_name = model
        # The TensorRT engine makes detection real-time on Jetson. If it is not
        # provided / does not exist, OwlPredictor falls back to plain PyTorch
        # (slower, but still functional).
        self.image_encoder_engine = image_encoder_engine or os.environ.get(
            "NANOOWL_IMAGE_ENCODER_ENGINE"
        )
        self.threshold = self._coerce_threshold(threshold, default=0.1)

        self.available = _NANOOWL_AVAILABLE
        self.predictor = None
        self.load_error: Optional[str] = (
            str(_NANOOWL_IMPORT_ERROR) if _NANOOWL_IMPORT_ERROR else None
        )

        self._labels: list[str] = []
        self._text_encodings = None
        self._encode_lock = threading.Lock()
        self._infer_lock = asyncio.Lock()

        self.current_detections: list[dict] = []
        self.is_processing = False
        self.last_inference_time = 0.0

        if self.available:
            self._load()

    # ------------------------------------------------------------------ setup

    def _load(self) -> None:
        """Load the OWL-ViT predictor (and TensorRT engine if available)."""
        try:
            kwargs: dict[str, Any] = {}

            # Pick a device: explicit override, else CUDA when present, else CPU.
            # OwlPredictor defaults to "cuda" and would crash on CPU-only hosts.
            device = os.environ.get("NANOOWL_DEVICE")
            if not device:
                try:
                    import torch  # nanoowl dependency, safe here

                    device = "cuda" if torch.cuda.is_available() else "cpu"
                except Exception:
                    device = "cpu"
            kwargs["device"] = device
            if device == "cpu":
                logger.warning(
                    "NanoOWL: running on CPU (no CUDA detected) \u2014 detection "
                    "will be slow. A CUDA GPU / Jetson is strongly recommended."
                )

            engine = self.image_encoder_engine
            if engine and os.path.exists(engine):
                kwargs["image_encoder_engine"] = engine
                logger.info(f"NanoOWL: using TensorRT image encoder engine: {engine}")
            elif engine:
                logger.warning(
                    f"NanoOWL: engine path not found ({engine}); "
                    "falling back to PyTorch (slower)."
                )
            else:
                logger.info(
                    "NanoOWL: no TensorRT engine configured "
                    "(set NANOOWL_IMAGE_ENCODER_ENGINE); using PyTorch."
                )

            self.predictor = OwlPredictor(self.model_name, **kwargs)
            logger.info(
                f"NanoOWL detector loaded: model={self.model_name}, device={device}"
            )
        except Exception as exc:  # pragma: no cover - environment dependent
            logger.error(f"NanoOWL: failed to load predictor: {exc}", exc_info=True)
            self.available = False
            self.predictor = None
            self.load_error = str(exc)

    @staticmethod
    def _coerce_threshold(value: Any, default: float) -> float:
        try:
            return max(0.0, min(1.0, float(value)))
        except (TypeError, ValueError):
            return default

    # ---------------------------------------------------------------- queries

    def set_query(self, query: str) -> list[str]:
        """
        Set the detection prompt. Accepts a comma/semicolon/newline separated
        list of object descriptions (e.g. "a hand, a face, a coffee cup").

        Re-encodes the text only when the labels actually change.
        """
        labels = [part.strip() for part in re.split(r"[,;\n]", query or "") if part.strip()]
        if labels == self._labels:
            return self._labels

        self._labels = labels
        if self.predictor is not None and labels:
            try:
                with self._encode_lock:
                    self._text_encodings = self.predictor.encode_text(labels)
                logger.info(f"NanoOWL: query set to {labels}")
            except Exception as exc:
                logger.error(f"NanoOWL: failed to encode text {labels}: {exc}")
                self._text_encodings = None
        else:
            self._text_encodings = None
        return self._labels

    def set_threshold(self, threshold: Any) -> None:
        self.threshold = self._coerce_threshold(threshold, default=self.threshold)

    def clear(self) -> None:
        self.current_detections = []

    @property
    def enabled(self) -> bool:
        return self.predictor is not None and bool(self._labels)

    # -------------------------------------------------------------- inference

    async def process_frame(self, image: Image.Image) -> None:
        """
        Run detection on a frame asynchronously. Updates ``current_detections``.
        Skips the frame if a detection is already in flight (drop, don't queue).
        """
        if not self.enabled:
            return
        if self._infer_lock.locked():
            return

        async with self._infer_lock:
            self.is_processing = True
            try:
                loop = asyncio.get_event_loop()
                detections = await loop.run_in_executor(None, self._detect_sync, image)
                self.current_detections = detections
            except Exception as exc:
                logger.error(f"NanoOWL: detection error: {exc}", exc_info=True)
            finally:
                self.is_processing = False

    def _detect_sync(self, image: Image.Image) -> list[dict]:
        labels = list(self._labels)
        encodings = self._text_encodings
        if not labels or encodings is None or self.predictor is None:
            return []

        start = time.perf_counter()
        output = self.predictor.predict(
            image=image,
            text=labels,
            text_encodings=encodings,
            threshold=self.threshold,
            pad_square=False,
        )
        self.last_inference_time = time.perf_counter() - start
        return self._format_output(output, image.width, image.height, labels)

    @staticmethod
    def _format_output(output: Any, width: int, height: int, labels: list[str]) -> list[dict]:
        """Convert NanoOWL output (pixel xyxy) to normalized UI detections."""
        if width <= 0 or height <= 0:
            return []

        boxes = getattr(output, "boxes", None)
        if boxes is None:
            return []
        scores = getattr(output, "scores", None)
        out_labels = getattr(output, "labels", None)

        def _to_list(tensor):
            if tensor is None:
                return []
            tolist = getattr(tensor, "tolist", None)
            if callable(tolist):
                try:
                    return tensor.detach().cpu().tolist()
                except AttributeError:
                    return tensor.tolist()
            return list(tensor)

        boxes_list = _to_list(boxes)
        scores_list = _to_list(scores)
        labels_list = _to_list(out_labels)

        results: list[dict] = []
        for i, box in enumerate(boxes_list):
            if box is None or len(box) < 4:
                continue
            x1, y1, x2, y2 = box[0], box[1], box[2], box[3]
            x = max(0.0, min(1.0, x1 / width))
            y = max(0.0, min(1.0, y1 / height))
            w = max(0.0, min(1.0 - x, (x2 - x1) / width))
            h = max(0.0, min(1.0 - y, (y2 - y1) / height))
            if w <= 0.0 or h <= 0.0:
                continue

            confidence = float(scores_list[i]) if i < len(scores_list) else None
            label_index = int(labels_list[i]) if i < len(labels_list) else 0
            label = labels[label_index] if 0 <= label_index < len(labels) else "object"

            results.append(
                {
                    "label": label,
                    "confidence": confidence,
                    "bbox": {"x": x, "y": y, "w": w, "h": h},
                }
            )
        return results

    # ------------------------------------------------------------------ state

    def get_current_detections(self) -> list[dict]:
        return self.current_detections

    def get_status(self) -> dict:
        return {
            "available": self.available,
            "enabled": self.enabled,
            "labels": list(self._labels),
            "threshold": self.threshold,
            "engine": bool(self.image_encoder_engine and os.path.exists(self.image_encoder_engine))
            if self.image_encoder_engine
            else False,
            "error": self.load_error,
        }
