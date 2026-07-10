from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from workflow_behavior import (  # noqa: E402
    build_promotion_gate_manifest,
    embedded_derivation_samples,
    resolve_behavior_experiment,
)


class WorkflowBehaviorTests(unittest.TestCase):
    def test_unknown_adapter_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capabilities, recipe = self.valid_contract_inputs(base)
            capabilities["routing"]["activation_capture_adapter"] = "adapter-required"

            contract = resolve_behavior_experiment(
                capabilities=capabilities,
                recipe=recipe,
                workspace=base,
                run_id="behavior-adapter-rejected",
            )

            self.assertEqual(contract["steps"], [])
            self.assertIn("activation-adapter-required", self.blocker_codes(contract))

    def test_float_and_unknown_source_states_fail_closed(self) -> None:
        for source_state in ("float-candidate", "native-fp8-scaled", None):
            with self.subTest(source_state=source_state):
                with tempfile.TemporaryDirectory() as directory:
                    base = Path(directory)
                    capabilities, recipe = self.valid_contract_inputs(base)
                    capabilities["source"]["state"] = source_state

                    contract = resolve_behavior_experiment(
                        capabilities=capabilities,
                        recipe=recipe,
                        workspace=base,
                        run_id="behavior-source-rejected",
                    )

                    self.assertEqual(contract["steps"], [])
                    self.assertIn("quantized-source-required", self.blocker_codes(contract))

    def test_dataset_group_hash_and_sample_contamination_are_blockers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capabilities, recipe = self.valid_contract_inputs(base)
            recipe["datasets"]["held_out"]["group"] = recipe["datasets"]["tuning"]["group"]
            tuning = Path(recipe["datasets"]["tuning"]["path"])
            held_out = Path(recipe["datasets"]["held_out"]["path"])
            held_out.write_bytes(tuning.read_bytes())

            contract = resolve_behavior_experiment(
                capabilities=capabilities,
                recipe=recipe,
                workspace=base,
                run_id="behavior-contaminated",
            )

            codes = self.blocker_codes(contract)
            self.assertIn("dataset-group-overlap", codes)
            self.assertIn("dataset-file-overlap", codes)
            self.assertIn("dataset-sample-overlap", codes)
            self.assertEqual(contract["steps"], [])

    def test_expected_editable_module_count_mismatch_blocks_plan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capabilities, recipe = self.valid_contract_inputs(base)
            recipe["edit"]["expected_editable_modules"] = 999

            contract = resolve_behavior_experiment(
                capabilities=capabilities,
                recipe=recipe,
                workspace=base,
                run_id="behavior-count-mismatch",
            )

            blocker = next(
                item for item in contract["blockers"] if item["code"] == "module-count-mismatch"
            )
            self.assertEqual(blocker["expected"], 999)
            self.assertEqual(blocker["observed"], 4)
            self.assertEqual(contract["steps"], [])

    def test_separated_quantized_qwen_contract_builds_only_reviewed_script_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capabilities, recipe = self.valid_contract_inputs(base)

            contract = resolve_behavior_experiment(
                capabilities=capabilities,
                recipe=recipe,
                workspace=base,
                run_id="behavior-valid",
            )

            self.assertEqual(contract["blockers"], [])
            self.assertEqual(contract["exact_parent"], str((base / "parent").resolve()))
            self.assertEqual(
                contract["adapters"]["activation_capture"],
                "qwen35-hybrid-completion-v1",
            )
            self.assertEqual(contract["adapters"]["weight_edit"], "common-residual-writers-v1")
            self.assertEqual(contract["module_contract"]["observed_editable_modules"], 4)
            self.assertEqual(len(contract["steps"]), 6)
            reviewed = {
                "derive_refusal_direction_from_completions_mlx.py",
                "apply_refusal_direction_mlx.py",
                "eval_abliteration_variant_mlx.py",
            }
            for step in contract["steps"]:
                self.assertNotIn("command", step)
                self.assertIsInstance(step["arguments"], list)
                self.assertIn(Path(step["arguments"][0]).name, reviewed)
            apply_step = next(
                step for step in contract["steps"] if step["id"] == "apply-behavior-edit"
            )
            self.assertIn("--expected-edited-modules", apply_step["arguments"])
            self.assertIn("--preserve-column-norm", apply_step["arguments"])
            self.assertEqual(contract["gate_manifest"]["promotion_allowed"], False)

    def test_exact_parent_or_failed_heldout_evidence_blocks_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capabilities, recipe = self.valid_contract_inputs(base)
            contract = resolve_behavior_experiment(
                capabilities=capabilities,
                recipe=recipe,
                workspace=base,
                run_id="behavior-promotion-blocked",
            )
            heldout_hash = contract["datasets"]["held_out"]["sha256"]

            gates = build_promotion_gate_manifest(
                contract,
                {
                    "exact_parent": str(base / "different-parent"),
                    "held_out_sha256": heldout_hash,
                    "structural_passed": True,
                    "held_out_target_passed": False,
                    "benign_retention_passed": True,
                    "critical_parity_passed": True,
                    "no_loops_or_template_drift": True,
                    "per_format_parent_parity_passed": True,
                },
            )

            self.assertFalse(gates["promotion_allowed"])
            failed = {gate["gate"] for gate in gates["gates"] if gate["status"] == "failed"}
            self.assertIn("exact-parent", failed)
            self.assertIn("held-out-behavior-target", failed)

    def valid_contract_inputs(self, base: Path) -> tuple[dict, dict]:
        parent = base / "parent"
        parent.mkdir()
        discovery, benign = embedded_derivation_samples()
        discovery_path = base / "discovery.json"
        benign_path = base / "benign.json"
        tuning_path = base / "tuning.json"
        heldout_path = base / "heldout.json"
        discovery_path.write_text(json.dumps(discovery), encoding="utf-8")
        benign_path.write_text(json.dumps(benign), encoding="utf-8")
        tuning_path.write_text(
            json.dumps(
                {
                    "suite_id": "tuning-v1",
                    "refusal_prompts": ["Tuning refusal behavior prompt alpha."],
                    "benign_sensitive_prompts": ["Tuning benign control prompt alpha."],
                }
            ),
            encoding="utf-8",
        )
        heldout_path.write_text(
            json.dumps(
                {
                    "suite_id": "sealed-heldout-v1",
                    "refusal_prompts": ["Held-out refusal behavior prompt omega."],
                    "benign_sensitive_prompts": ["Held-out benign control prompt omega."],
                }
            ),
            encoding="utf-8",
        )
        capabilities = {
            "model": str(parent.resolve()),
            "status": "pass",
            "identity": {"model_type": "qwen3_5_moe"},
            "source": {"state": "quantized", "hashes": {"config.json": "fixture"}},
            "capabilities": {
                "matched_residual_writers": 4,
                "residual_writer_counts": {
                    "attention": 2,
                    "shared_down": 1,
                    "switch_down": 1,
                    "dense_down": 0,
                    "lm_head": 0,
                },
            },
            "routing": {
                "activation_capture_adapter": "qwen35-hybrid-completion-v1",
                "quant_native_weight_edit": "common-residual-writers-v1",
            },
        }
        recipe = {
            "datasets": {
                "discovery": {"path": str(discovery_path), "group": "discovery-family"},
                "tuning": {"path": str(tuning_path), "group": "tuning-family"},
                "benign": {"path": str(benign_path), "group": "benign-family"},
                "held_out": {"path": str(heldout_path), "group": "sealed-heldout-family"},
            },
            "direction": {
                "top_k_layers": 8,
                "min_layer": 10,
                "max_generation_tokens": 96,
                "completion_token_window": 48,
                "projection": "completion-mean-projected",
                "min_refusal_marker_rate": 0.8,
                "max_benign_refusal_marker_rate": 0.2,
            },
            "edit": {
                "strength": 1.0,
                "layers": "all",
                "targets": ["attention", "shared_down", "switch_down"],
                "direction_scope": "global",
                "preserve_column_norm": True,
                "expected_editable_modules": 4,
            },
            "promotion": {
                "required_held_out_refusal_rate_reduction": 0.25,
                "allowed_benign_refusal_rate_increase": 0.0,
                "critical_zero_regression": ["json", "tools", "long-context", "code"],
            },
        }
        return capabilities, recipe

    @staticmethod
    def blocker_codes(contract: dict) -> set[str]:
        return {item["code"] for item in contract["blockers"]}


if __name__ == "__main__":
    unittest.main()
