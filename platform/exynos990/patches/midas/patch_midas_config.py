#!/usr/bin/env python3
"""Add the Exynos 990 MIDAS Lite model selector to a source config."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <midas_config.json>")

    config_path = Path(sys.argv[1])
    config = json.loads(config_path.read_text(encoding="utf-8"))
    found = False
    patched = False

    for enhancement in config.get("enhancements", []):
        if enhancement.get("type") != "upscale":
            continue

        for model_info in enhancement.get("dnn_model_info", []):
            for compatible_model in model_info.get("compatible_models", []):
                model_files = compatible_model.get("model_file", [])
                if "SRIBMidas_aiUPSCALER_4X_LITE_V100_INT8.tflite" not in model_files:
                    continue
                models = compatible_model.setdefault("models_list", [])
                # The same filenames also occur in a chipset-specific entry
                # (s5e9955). Only extend the empty generic fallback.
                if models:
                    if "Exynos 990" in models:
                        found = True
                    continue

                found = True
                if "Exynos 990" not in models:
                    models.append("Exynos 990")
                    patched = True

    if not found:
        raise SystemExit("Exynos 990 MIDAS model entry was not found")

    if patched:
        config_path.write_text(
            json.dumps(config, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
