from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".venv" / "bin" / "python"
CLI = ROOT / "scripts" / "mlx_workflow_cli.py"
FIXTURE = ROOT / "scripts" / "create_tiny_llama_fixture.py"

import sys

sys.path.insert(0, str(ROOT / "scripts"))

from workflow_promotion import snapshot_artifact


def invoke(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(PYTHON), str(CLI), "--machine", *arguments],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


class TinyRealWorkflowTests(unittest.TestCase):
    def test_real_tiny_quantization_qualifies_only_with_hashed_parent_relative_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            workspace = base / "runs"
            workspace.mkdir()
            created = subprocess.run(
                [str(PYTHON), str(FIXTURE), "--output", str(source), "--seed", "7"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(created.returncode, 0, created.stderr)
            parent_before = snapshot_artifact(source)
            plan_path = base / "tiny-real.plan.json"
            planned = invoke(
                "plan",
                "--workspace",
                str(workspace),
                "--run-id",
                "tiny-real",
                "--model",
                str(source),
                "--operation",
                "quantize",
                "--quant-mode",
                "mxfp4",
                "--time-budget-seconds",
                "600",
                "--context-target-tokens",
                "256",
                "--output",
                str(plan_path),
            )
            self.assertEqual(planned.returncode, 0, planned.stderr)
            digest = hashlib.sha256(plan_path.read_bytes()).hexdigest()
            executed = invoke(
                "run",
                "--plan",
                str(plan_path),
                "--expected-plan-sha256",
                digest,
            )
            self.assertEqual(executed.returncode, 0, executed.stderr)
            run_dir = workspace / "tiny-real"

            qualified = invoke("qualify", "--run-dir", str(run_dir))

            self.assertEqual(qualified.returncode, 0, qualified.stderr)
            self.assertEqual(snapshot_artifact(source), parent_before)
            manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertTrue(manifest["qualified"])
            gates = json.loads((run_dir / "gates.json").read_text(encoding="utf-8"))
            self.assertEqual(
                gates["required"],
                [
                    "provenance-structure",
                    "deterministic-language-schema",
                    "parent-parity",
                ],
            )
            self.assertTrue(all(item["status"] == "passed" for item in gates["gates"]))
            for item in gates["gates"]:
                evidence = run_dir / item["evidence"]
                self.assertTrue(evidence.is_file())
                self.assertEqual(hashlib.sha256(evidence.read_bytes()).hexdigest(), item["sha256"])
            runtime = json.loads(
                (run_dir / "evaluations" / "deterministic-language-schema.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertTrue(runtime["parent"]["load_passed"])
            self.assertTrue(runtime["candidate"]["load_passed"])
            self.assertTrue(runtime["candidate"]["repeat_deterministic"])


if __name__ == "__main__":
    unittest.main()
