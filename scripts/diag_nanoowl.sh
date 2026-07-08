#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
echo "=== interpreter ==="
.venv/bin/python -c "import sys; print(sys.executable)"
echo "=== live_vlm_webui ==="
.venv/bin/python -c "import live_vlm_webui; print('OK', live_vlm_webui.__file__)" 2>&1 | tail -2
echo "=== transformers ==="
.venv/bin/python -c "import transformers; print('transformers', transformers.__version__)" 2>&1 | tail -2
echo "=== which python ==="
ls -la .venv/bin/python* 2>/dev/null || echo "no .venv/bin/python"
echo "=== pip show nanoowl ==="
.venv/bin/python -m pip show nanoowl 2>&1 | head -5 || echo "pip show failed"
echo "=== import nanoowl ==="
.venv/bin/python - <<'PY' 2>&1 | head -40
try:
    import nanoowl
    print("nanoowl OK:", nanoowl.__file__)
    from nanoowl.owl_predictor import OwlPredictor
    print("OwlPredictor import OK")
except Exception as e:
    import traceback
    traceback.print_exc()
PY
echo "=== torch cuda ==="
.venv/bin/python -c "import torch; print('cuda:', torch.cuda.is_available())" 2>&1 | head -5
