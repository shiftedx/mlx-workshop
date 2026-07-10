from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

import sys

sys.path.insert(0, str(SCRIPTS))

from workflow_host import snapshot_host
from workflow_promotion import (
    PromotionError,
    evaluate_qualification,
    snapshot_artifact,
    stage_candidate,
)


class WorkflowHostPromotionTests(unittest.TestCase):
    def test_host_snapshot_reports_apple_runtime_and_sanitized_workloads(self) -> None:
        def command_result(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            outputs = {
                ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"): "Apple M3 Ultra\n",
                ("/usr/sbin/sysctl", "-n", "hw.memsize"): "68719476736\n",
                ("/usr/bin/pmset", "-g", "batt"): "Now drawing from 'AC Power'\n",
                ("/usr/bin/pmset", "-g", "therm"): "Note: No thermal warning level has been recorded\n",
                ("/bin/ps", "-axo", "pid=,command="): (
                    "101 /Applications/LM Studio.app/Contents/MacOS/LM Studio\n"
                    "202 /private/tmp/test-env/bin/python -m mlx_lm.server --token secret\n"
                    "303 /opt/homebrew/bin/mtplx.server\n"
                    "404 /usr/bin/unrelated\n"
                ),
                ("/opt/homebrew/bin/mtplx", "--version"): "mtplx 2.0.1\n",
            }
            return subprocess.CompletedProcess(command, 0, outputs.get(tuple(command), ""), "")

        versions = {
            "mlx": "0.31.2",
            "mlx-lm": "0.31.3",
            "transformers": "5.12.1",
        }

        with tempfile.TemporaryDirectory() as directory, mock.patch(
            "workflow_host.subprocess.run", side_effect=command_result
        ), mock.patch("workflow_host.platform.system", return_value="Darwin"), mock.patch(
            "workflow_host.platform.machine", return_value="arm64"
        ), mock.patch(
            "workflow_host.platform.mac_ver", return_value=("26.0", ("", "", ""), "")
        ), mock.patch(
            "workflow_host.metadata.version", side_effect=lambda name: versions[name]
        ), mock.patch(
            "workflow_host.shutil.which", return_value="/opt/homebrew/bin/mtplx"
        ):
            snapshot = snapshot_host(Path(directory))

        self.assertEqual(snapshot["hardware"]["chip"], "Apple M3 Ultra")
        self.assertEqual(snapshot["hardware"]["unified_memory_bytes"], 68_719_476_736)
        self.assertEqual(snapshot["macos"]["version"], "26.0")
        self.assertEqual(snapshot["versions"]["mlx_lm"], "0.31.3")
        self.assertEqual(snapshot["versions"]["mtplx"], "2.0.1")
        self.assertEqual(snapshot["power"]["source"], "ac")
        self.assertEqual(snapshot["thermal"]["state"], "nominal")
        self.assertEqual(
            snapshot["active_workloads"],
            [
                {"pid": 101, "kind": "lm-studio", "process": "LM Studio"},
                {"pid": 202, "kind": "mlx-lm", "process": "python"},
                {"pid": 303, "kind": "mtplx", "process": "mtplx.server"},
            ],
        )
        serialized = str(snapshot)
        self.assertNotIn("alice", serialized)
        self.assertNotIn("secret", serialized)

    def test_qualification_passes_only_frozen_gates_with_raw_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            evidence_dir = base / "evidence"
            evidence_dir.mkdir()
            for name in ("provenance", "structure", "deterministic", "runtime", "performance"):
                (evidence_dir / f"{name}.json").write_text("{}\n", encoding="utf-8")
            evidence = {
                "schema_version": 1,
                "exact_parent": "parent-sha256",
                "candidate": "candidate-sha256",
                "frozen_contract": {
                    "runtime": "mlx-lm-0.31.3",
                    "template_sha256": "template-sha256",
                    "context": 4096,
                    "seed": 7,
                },
                "required_gates": [
                    "provenance",
                    "structure",
                    "deterministic",
                    "runtime",
                    "performance",
                ],
                "gates": [
                    {
                        "name": name,
                        "status": "passed",
                        "evidence": [f"evidence/{name}.json"],
                    }
                    for name in (
                        "provenance",
                        "structure",
                        "deterministic",
                        "runtime",
                        "performance",
                    )
                ],
                "performance": {
                    "metric": "tokens_per_second",
                    "minimum_improvement_fraction": 0.05,
                    "maximum_coefficient_of_variation": 0.05,
                    "parent_samples": [
                        {"case": "a", "value": 99.0},
                        {"case": "b", "value": 100.0},
                        {"case": "c", "value": 101.0},
                    ],
                    "candidate_samples": [
                        {"case": "a", "value": 109.0},
                        {"case": "b", "value": 110.0},
                        {"case": "c", "value": 111.0},
                    ],
                },
            }

            result = evaluate_qualification(evidence, evidence_root=base)

        self.assertTrue(result["qualified"])
        self.assertEqual(result["classification"], "qualified")
        self.assertEqual(result["blockers"], [])
        self.assertEqual(len(result["raw_evidence"]), 5)
        self.assertGreater(result["performance"]["improvement_fraction"], 0.05)

    def test_qualification_rejects_missing_failed_and_pending_required_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "failed.json").write_text("{}\n", encoding="utf-8")
            (base / "pending.json").write_text("{}\n", encoding="utf-8")
            evidence = {
                "schema_version": 1,
                "exact_parent": "parent-sha256",
                "candidate": "candidate-sha256",
                "frozen_contract": {"runtime": "mlx-lm-0.31.3", "seed": 7},
                "required_gates": ["missing", "failed", "pending"],
                "gates": [
                    {"name": "failed", "status": "failed", "evidence": ["failed.json"]},
                    {"name": "pending", "status": "pending", "evidence": ["pending.json"]},
                ],
            }

            result = evaluate_qualification(evidence, evidence_root=base)

        self.assertFalse(result["qualified"])
        self.assertEqual(result["classification"], "experimental")
        self.assertIn("gate-missing:missing", result["blockers"])
        self.assertIn("gate-not-passed:failed", result["blockers"])
        self.assertIn("gate-not-passed:pending", result["blockers"])

    def test_qualification_rejects_noisy_performance_claim(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "performance.json").write_text("{}\n", encoding="utf-8")
            evidence = {
                "schema_version": 1,
                "exact_parent": "parent-sha256",
                "candidate": "candidate-sha256",
                "frozen_contract": {"runtime": "mlx-lm-0.31.3", "seed": 7},
                "required_gates": ["performance"],
                "gates": [
                    {
                        "name": "performance",
                        "status": "passed",
                        "evidence": ["performance.json"],
                    }
                ],
                "performance": {
                    "metric": "tokens_per_second",
                    "minimum_improvement_fraction": 0.05,
                    "maximum_coefficient_of_variation": 0.05,
                    "parent_samples": [
                        {"case": "a", "value": 99.0},
                        {"case": "b", "value": 100.0},
                        {"case": "c", "value": 101.0},
                    ],
                    "candidate_samples": [
                        {"case": "a", "value": 60.0},
                        {"case": "b", "value": 130.0},
                        {"case": "c", "value": 200.0},
                    ],
                },
            }

            result = evaluate_qualification(evidence, evidence_root=base)

        self.assertFalse(result["qualified"])
        self.assertIn("performance-claim-noisy", result["blockers"])
        self.assertGreater(result["performance"]["improvement_fraction"], 0.05)

    def test_staging_creates_metadata_only_new_directory_and_preserves_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            parent = base / "parent"
            candidate = base / "candidate"
            staging_root = base / "staging"
            evidence_root = base / "run"
            parent.mkdir()
            candidate.mkdir()
            staging_root.mkdir()
            evidence_root.mkdir()
            (parent / "weights.bin").write_bytes(b"immutable-parent")
            (candidate / "weights.bin").write_bytes(b"candidate-output")
            (evidence_root / "structure.json").write_text("{}\n", encoding="utf-8")
            parent_before = snapshot_artifact(parent)
            candidate_before = snapshot_artifact(candidate)
            qualification = evaluate_qualification(
                {
                    "schema_version": 1,
                    "exact_parent": parent_before["tree_sha256"],
                    "candidate": candidate_before["tree_sha256"],
                    "frozen_contract": {"runtime": "mlx-lm-0.31.3", "seed": 7},
                    "required_gates": ["structure"],
                    "gates": [
                        {
                            "name": "structure",
                            "status": "passed",
                            "evidence": ["structure.json"],
                        }
                    ],
                },
                evidence_root=evidence_root,
            )

            stage = stage_candidate(
                parent=parent,
                candidate=candidate,
                staging_root=staging_root,
                stage_id="candidate-v1",
                qualification=qualification,
            )

            self.assertEqual(snapshot_artifact(parent), parent_before)
            self.assertEqual(snapshot_artifact(candidate), candidate_before)
            self.assertEqual(stage, staging_root.resolve() / "candidate-v1")
            self.assertEqual(
                sorted(path.name for path in stage.iterdir()),
                ["hashes.json", "rollback.json", "staging-manifest.json"],
            )
            manifest = json.loads((stage / "staging-manifest.json").read_text(encoding="utf-8"))
            rollback = json.loads((stage / "rollback.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["classification"], "qualified")
            self.assertEqual(manifest["artifact_mode"], "reference-only")
            self.assertEqual(rollback["exact_parent"], str(parent.resolve()))
            self.assertTrue(rollback["parent_unchanged"])
            self.assertFalse((stage / "weights.bin").exists())

            with self.assertRaises(FileExistsError):
                stage_candidate(
                    parent=parent,
                    candidate=candidate,
                    staging_root=staging_root,
                    stage_id="candidate-v1",
                    qualification=qualification,
                )

    def test_staging_rejects_candidate_changed_after_qualification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            parent = base / "parent"
            candidate = base / "candidate"
            staging_root = base / "staging"
            evidence_root = base / "run"
            for path in (parent, candidate, staging_root, evidence_root):
                path.mkdir()
            (parent / "weights.bin").write_bytes(b"parent")
            (candidate / "weights.bin").write_bytes(b"candidate")
            (evidence_root / "structure.json").write_text("{}\n", encoding="utf-8")
            qualification = evaluate_qualification(
                {
                    "schema_version": 1,
                    "exact_parent": snapshot_artifact(parent)["tree_sha256"],
                    "candidate": snapshot_artifact(candidate)["tree_sha256"],
                    "frozen_contract": {"runtime": "mlx-lm-0.31.3"},
                    "required_gates": ["structure"],
                    "gates": [
                        {
                            "name": "structure",
                            "status": "passed",
                            "evidence": ["structure.json"],
                        }
                    ],
                },
                evidence_root=evidence_root,
            )
            (candidate / "weights.bin").write_bytes(b"changed-after-qualification")

            with self.assertRaisesRegex(PromotionError, "candidate does not match"):
                stage_candidate(
                    parent=parent,
                    candidate=candidate,
                    staging_root=staging_root,
                    stage_id="changed-candidate",
                    qualification=qualification,
                )

            self.assertFalse((staging_root / "changed-candidate").exists())


if __name__ == "__main__":
    unittest.main()
