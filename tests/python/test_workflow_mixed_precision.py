from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from workflow_mixed_precision import (  # noqa: E402
    MLXLayerAdapter,
    MLXLogitsKLEvaluator,
    apply_assignment,
    build_sensitivity_request,
)
from workflow_sensitivity import analyze_sensitivity  # noqa: E402


MODEL = ROOT / "tests" / "fixtures" / "tiny-llama-float"


class WorkflowMixedPrecisionTests(unittest.TestCase):
    def test_measures_layer_sensitivity_and_materializes_exact_reloadable_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            adapter = MLXLayerAdapter.inspect(MODEL)
            self.assertEqual(
                [item.identifier.canonical for item in adapter.modules],
                ["layer.0.transformer-block", "layer.1.transformer-block"],
            )
            evaluator = MLXLogitsKLEvaluator(
                model_path=MODEL,
                token_batches=((1, 4, 5, 6), (1, 7, 8, 9)),
                evidence_dir=root / "measurements",
            )
            request = build_sensitivity_request(
                adapter=adapter,
                model_path=MODEL,
                token_batches=evaluator.token_batches,
                max_search_states=32,
            )

            result = analyze_sensitivity(request, evaluator)

            self.assertEqual(result.status, "supported")
            self.assertEqual(len(result.measurements), 4)
            self.assertTrue(all(item.delta >= 0 for item in result.measurements))
            self.assertTrue(all((root / item.evidence_ref).is_file() for item in result.measurements))

            assignment = {
                "layer.0.transformer-block": "mxfp4",
                "layer.1.transformer-block": "mxfp8",
            }
            output = root / "mixed-model"
            manifest = apply_assignment(
                model_path=MODEL,
                output_path=output,
                adapter=adapter,
                assignments=assignment,
            )
            config = json.loads((output / "config.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["assignments"], assignment)
            self.assertEqual(
                config["quantization"]["model.layers.0.mlp.up_proj"]["mode"], "mxfp4"
            )
            self.assertEqual(
                config["quantization"]["model.layers.1.mlp.up_proj"]["mode"], "mxfp8"
            )

            from mlx_lm import load

            load(str(output), lazy=False)


if __name__ == "__main__":
    unittest.main()
