from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".venv" / "bin" / "python"
SCRIPT = ROOT / "scripts" / "create_tiny_llama_fixture.py"
sys.path.insert(0, str(ROOT / "scripts"))

from inspect_mlx_model import inspect_model


class TinyLlamaFixtureTests(unittest.TestCase):
    def test_creates_a_deterministic_loadable_float_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "tiny-llama-float"

            result = subprocess.run(
                [str(PYTHON), str(SCRIPT), "--output", str(output), "--seed", "7"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "source-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["kind"], "deterministic-tiny-llama-float-source")
            self.assertEqual(manifest["seed"], 7)
            self.assertEqual(manifest["model_type"], "llama")
            self.assertEqual(len(manifest["files"]), 6)
            self.assertTrue(all(len(item["sha256"]) == 64 for item in manifest["files"]))
            duplicate = Path(directory) / "tiny-llama-float-duplicate"
            duplicate_result = subprocess.run(
                [str(PYTHON), str(SCRIPT), "--output", str(duplicate), "--seed", "7"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(duplicate_result.returncode, 0, duplicate_result.stderr)
            duplicate_manifest = json.loads(
                (duplicate / "source-manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(duplicate_manifest["files"], manifest["files"])

            capability = inspect_model(output)
            self.assertEqual(capability["status"], "pass")
            self.assertEqual(capability["source"]["state"], "float-candidate")
            self.assertTrue(capability["routing"]["conversion"]["allowed"])

            smoke = subprocess.run(
                [
                    str(PYTHON),
                    "-c",
                    (
                        "from mlx_lm import load, generate; import sys; "
                        "model, tokenizer = load(sys.argv[1]); "
                        "print(generate(model, tokenizer, prompt='user: hello\\nassistant:', "
                        "max_tokens=4, verbose=False))"
                    ),
                    str(output),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(smoke.returncode, 0, smoke.stderr)


if __name__ == "__main__":
    unittest.main()
