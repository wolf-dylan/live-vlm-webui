"""Unit tests for the optional NanoOWL detector wrapper."""

from types import SimpleNamespace

from PIL import Image

from live_vlm_webui import detector_service


class FakePredictor:
    instances = 0

    def __init__(self, model, **kwargs):
        type(self).instances += 1
        self.model = model
        self.kwargs = kwargs

    def encode_text(self, labels):
        return tuple(labels)

    def predict(self, **kwargs):
        return SimpleNamespace(
            boxes=[[10, 20, 60, 80]],
            scores=[0.75],
            labels=[0],
        )


def test_detector_defers_model_load_until_query(monkeypatch):
    FakePredictor.instances = 0
    monkeypatch.setattr(detector_service, "OwlPredictor", FakePredictor)
    monkeypatch.setenv("NANOOWL_DEVICE", "cpu")

    detector = detector_service.NanoOwlDetector()

    assert detector.get_status()["initialized"] is False
    assert FakePredictor.instances == 0

    detector.set_query("a hand, a cup")

    assert detector.get_status()["initialized"] is True
    assert detector.enabled is True
    assert FakePredictor.instances == 1


def test_detector_formats_normalized_boxes(monkeypatch):
    monkeypatch.setattr(detector_service, "OwlPredictor", FakePredictor)
    monkeypatch.setenv("NANOOWL_DEVICE", "cpu")
    detector = detector_service.NanoOwlDetector()
    detector.set_query("object")

    detections = detector._detect_sync(Image.new("RGB", (100, 100)))

    assert detections == [
        {
            "label": "object",
            "confidence": 0.75,
            "bbox": {"x": 0.1, "y": 0.2, "w": 0.5, "h": 0.6},
        }
    ]
