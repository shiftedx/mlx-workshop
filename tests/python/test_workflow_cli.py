from __future__ import annotations

import json
import hashlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from safetensors.numpy import save_file


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".venv" / "bin" / "python"
CLI = ROOT / "scripts" / "mlx_workflow_cli.py"
sys.path.insert(0, str(ROOT / "scripts"))

from workflow_plan import resolve_plan


def invoke(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(PYTHON), str(CLI), "--machine", *arguments],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def events(result: subprocess.CompletedProcess[str]) -> list[dict]:
    return [json.loads(line) for line in result.stdout.splitlines() if line]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def terminal_event(journal: list[dict]) -> dict:
    terminal_states = {"blocked", "cancelled", "completed", "failed", "interrupted"}
    return next(
        event
        for event in reversed(journal)
        if event["payload"].get("state") in terminal_states
    )


def create_float_model(base: Path, name: str = "tiny-llama") -> Path:
    model = base / name
    model.mkdir()
    (model / "config.json").write_text(
        json.dumps(
            {
                "model_type": "llama",
                "architectures": ["LlamaForCausalLM"],
                "hidden_size": 2,
                "num_hidden_layers": 1,
            }
        ),
        encoding="utf-8",
    )
    shard = model / "model-00001-of-00001.safetensors"
    save_file(
        {"model.layers.0.self_attn.o_proj.weight": np.zeros((2, 2), dtype=np.float32)},
        shard,
    )
    (model / "model.safetensors.index.json").write_text(
        json.dumps({"weight_map": {"model.layers.0.self_attn.o_proj.weight": shard.name}}),
        encoding="utf-8",
    )
    return model


def canonical_recipe(model: Path) -> dict:
    return {
        "schema_version": 1,
        "exact_parent": str(model.resolve()),
        "operations": ["quantize"],
        "quant_modes": ["mxfp4"],
        "allocation": {
            "strategy": "uniform",
            "target_bpw": 4.0,
            "kl_tolerance": None,
            "per_module_overrides": False,
        },
        "priorities": {"quality": 0.78, "size": 0.58},
        "time_budget_seconds": 3600,
        "context_target_tokens": 32768,
        "calibration": {
            "identity": "not-applicable",
            "dataset_sha256": None,
            "sample_budget": 0,
            "token_budget": 0,
            "seed": None,
        },
        "protection_rules": {
            "preserve_embeddings": False,
            "preserve_output_head": False,
            "protect_sensitive_modules": False,
        },
        "validation": {
            "required_gates": [
                "provenance-structure",
                "deterministic-language-schema",
                "parent-parity",
            ],
            "critical_regressions_allowed": 0,
        },
    }


def planning_capabilities(
    model: Path, *, source_bytes: int = 1024, source_state: str = "float-candidate"
) -> dict:
    return {
        "model": str(model.resolve()),
        "status": "pass",
        "source": {"state": source_state, "disk_bytes": source_bytes},
        "routing": {"conversion": {"allowed": source_state == "float-candidate"}},
    }


def planning_host(
    *, free_disk_bytes: int = 100 * 1024**3, unified_memory_bytes: int | None = 64 * 1024**3
) -> dict:
    return {
        "disk": {"free_bytes": free_disk_bytes},
        "hardware": {"unified_memory_bytes": unified_memory_bytes},
        "active_workloads": [],
    }


def fixture_plan(base: Path, run_id: str, scenario: str, *, model: Path | None = None) -> Path:
    plan_path = base / f"{run_id}.plan.json"
    arguments = [
        "plan",
        "--workspace",
        str(base),
        "--run-id",
        run_id,
        "--fixture-scenario",
        scenario,
        "--output",
        str(plan_path),
    ]
    if model is not None:
        arguments.extend(["--model", str(model)])
    result = invoke(*arguments)
    expected = 3 if scenario == "block" else 0
    if result.returncode != expected:
        raise AssertionError(result.stderr)
    return plan_path


class WorkflowCLITests(unittest.TestCase):
    def test_inline_plan_options_normalize_to_the_canonical_real_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            plan_path = base / "canonical.plan.json"

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "canonical-plan",
                "--model",
                str(model),
                "--operation",
                "quantize",
                "--quant-mode",
                "mxfp4",
                "--quality-priority",
                "0.78",
                "--size-priority",
                "0.58",
                "--time-budget-seconds",
                "3600",
                "--context-target-tokens",
                "32768",
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual(plan["recipe"], canonical_recipe(model))

    def test_canonical_recipe_file_round_trips_without_losing_controls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            recipe = canonical_recipe(model)
            recipe["priorities"] = {"quality": 0.91, "size": 0.37}
            recipe["time_budget_seconds"] = 7200
            recipe["context_target_tokens"] = 65536
            recipe_path = base / "recipe.json"
            plan_path = base / "round-trip.plan.json"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "round-trip-plan",
                "--model",
                str(model),
                "--recipe",
                str(recipe_path),
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual(plan["recipe"], recipe)

    def test_real_plan_labels_deterministic_resource_bounds_as_estimates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            plan_path = base / "resources.plan.json"

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "resource-plan",
                "--model",
                str(model),
                "--operation",
                "quantize",
                "--quant-mode",
                "mxfp4",
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            estimate = json.loads(plan_path.read_text(encoding="utf-8"))["resource_estimate"]
            source_bytes = (model / "model-00001-of-00001.safetensors").stat().st_size
            output_bytes = (source_bytes * 45 + 99) // 100 + 64 * 1024**2
            temporary_bytes = source_bytes + 1024**3
            self.assertEqual(
                set(estimate),
                {
                    "kind",
                    "basis",
                    "uncertainty",
                    "source_bytes",
                    "estimated_output_bytes",
                    "estimated_temporary_bytes",
                    "disk_reserve_bytes",
                    "required_free_disk_bytes",
                    "observed_free_disk_bytes",
                    "estimated_peak_memory_bytes",
                    "memory_reserve_bytes",
                    "observed_unified_memory_bytes",
                    "usable_unified_memory_bytes",
                    "estimated_duration_seconds",
                    "time_budget_seconds",
                    "feasibility",
                    "reason_codes",
                },
            )
            self.assertEqual(estimate["kind"], "estimate")
            self.assertEqual(estimate["uncertainty"], "conservative-upper-bound")
            self.assertEqual(estimate["source_bytes"], source_bytes)
            self.assertEqual(estimate["estimated_output_bytes"], output_bytes)
            self.assertEqual(estimate["estimated_temporary_bytes"], temporary_bytes)
            self.assertEqual(
                estimate["required_free_disk_bytes"],
                output_bytes + temporary_bytes + 30 * 1024**3,
            )
            self.assertEqual(estimate["estimated_peak_memory_bytes"], source_bytes + 2 * 1024**3)
            self.assertIsNone(estimate["estimated_duration_seconds"])
            self.assertEqual(estimate["feasibility"], "review-required")
            self.assertIn("duration-estimate-unknown", estimate["reason_codes"])

    def test_unsupported_material_recipe_control_blocks_without_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            recipe = canonical_recipe(model)
            recipe["allocation"]["strategy"] = "mixed-precision"
            recipe_path = base / "unsupported-control.json"
            plan_path = base / "unsupported-control.plan.json"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "unsupported-control",
                "--model",
                str(model),
                "--recipe",
                str(recipe_path),
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 3, result.stderr)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual([item["code"] for item in plan["blockers"]], ["recipe-control-unsupported"])
            self.assertEqual(plan["steps"], [])
            self.assertEqual(plan["recipe"], recipe)

    def test_insufficient_disk_is_a_stable_resource_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            with mock.patch(
                "workflow_plan.inspect_model", return_value=planning_capabilities(model)
            ), mock.patch(
                "workflow_plan.snapshot_host", return_value=planning_host(free_disk_bytes=1)
            ):
                plan, _capabilities = resolve_plan(
                    workspace=base,
                    run_id="disk-blocked",
                    model=model,
                    recipe=recipe,
                )

            self.assertIn("resource-disk-insufficient", plan["resource_estimate"]["reason_codes"])
            self.assertEqual(plan["resource_estimate"]["feasibility"], "blocked")
            self.assertEqual(
                [item["code"] for item in plan["blockers"]],
                ["resource-disk-insufficient"],
            )
            self.assertEqual(plan["steps"], [])

    def test_unknown_model_size_nulls_derived_resource_values_and_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            with mock.patch(
                "workflow_plan.inspect_model",
                return_value=planning_capabilities(model, source_bytes=0),
            ), mock.patch("workflow_plan.snapshot_host", return_value=planning_host()):
                plan, _capabilities = resolve_plan(
                    workspace=base,
                    run_id="unknown-size",
                    model=model,
                    recipe=recipe,
                )

            estimate = plan["resource_estimate"]
            for field in (
                "source_bytes",
                "estimated_output_bytes",
                "estimated_temporary_bytes",
                "required_free_disk_bytes",
                "estimated_peak_memory_bytes",
            ):
                self.assertIsNone(estimate[field])
            self.assertIn("resource-model-size-unknown", estimate["reason_codes"])
            self.assertEqual(
                [item["code"] for item in plan["blockers"]],
                ["resource-model-size-unknown"],
            )
            self.assertEqual(plan["steps"], [])

    def test_conservative_peak_memory_overflow_blocks_without_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            with mock.patch(
                "workflow_plan.inspect_model",
                return_value=planning_capabilities(model, source_bytes=60 * 1024**3),
            ), mock.patch(
                "workflow_plan.snapshot_host",
                return_value=planning_host(
                    free_disk_bytes=200 * 1024**3,
                    unified_memory_bytes=64 * 1024**3,
                ),
            ):
                plan, _capabilities = resolve_plan(
                    workspace=base,
                    run_id="memory-blocked",
                    model=model,
                    recipe=recipe,
                )

            estimate = plan["resource_estimate"]
            self.assertEqual(estimate["usable_unified_memory_bytes"], 56 * 1024**3)
            self.assertEqual(estimate["estimated_peak_memory_bytes"], 62 * 1024**3)
            self.assertIn("resource-memory-insufficient", estimate["reason_codes"])
            self.assertEqual(
                [item["code"] for item in plan["blockers"]],
                ["resource-memory-insufficient"],
            )
            self.assertEqual(plan["steps"], [])

    def test_unknown_memory_and_active_workloads_require_review_but_do_not_block(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            host = planning_host(unified_memory_bytes=None)
            host["active_workloads"] = [{"pid": 123, "kind": "mlx-lm", "process": "python"}]
            with mock.patch(
                "workflow_plan.inspect_model", return_value=planning_capabilities(model)
            ), mock.patch("workflow_plan.snapshot_host", return_value=host):
                plan, _capabilities = resolve_plan(
                    workspace=base,
                    run_id="review-required",
                    model=model,
                    recipe=recipe,
                )

            estimate = plan["resource_estimate"]
            self.assertIsNone(estimate["observed_unified_memory_bytes"])
            self.assertIsNone(estimate["usable_unified_memory_bytes"])
            self.assertEqual(estimate["feasibility"], "review-required")
            self.assertEqual(
                estimate["reason_codes"],
                [
                    "active-workloads-present",
                    "duration-estimate-unknown",
                    "memory-observation-unknown",
                ],
            )
            self.assertEqual(plan["blockers"], [])
            self.assertEqual(len(plan["steps"]), 1)

    def test_quantized_and_native_fp8_sources_are_blocked_without_conversion_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            for source_state in ("quantized", "native-fp8-scaled"):
                with self.subTest(source_state=source_state), mock.patch(
                    "workflow_plan.inspect_model",
                    return_value=planning_capabilities(model, source_state=source_state),
                ), mock.patch("workflow_plan.snapshot_host", return_value=planning_host()):
                    plan, _capabilities = resolve_plan(
                        workspace=base,
                        run_id=f"{source_state}-source",
                        model=model,
                        recipe=recipe,
                    )

                self.assertEqual(
                    [item["code"] for item in plan["blockers"]],
                    ["source-state-unsupported"],
                )
                self.assertEqual(plan["steps"], [])

    def test_existing_immutable_run_directory_is_a_plan_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            (base / "already-exists").mkdir()
            with mock.patch(
                "workflow_plan.inspect_model", return_value=planning_capabilities(model)
            ), mock.patch("workflow_plan.snapshot_host", return_value=planning_host()):
                plan, _capabilities = resolve_plan(
                    workspace=base,
                    run_id="already-exists",
                    model=model,
                    recipe=recipe,
                )

            self.assertEqual(
                [item["code"] for item in plan["blockers"]],
                ["run-directory-exists"],
            )
            self.assertEqual(plan["steps"], [])

    def test_planning_rejects_a_run_workspace_inside_the_exact_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            workspace = model / "nested-runs"
            workspace.mkdir()
            recipe_path = base / "nested-recipe.json"
            recipe_path.write_text(json.dumps(canonical_recipe(model)), encoding="utf-8")
            plan_path = base / "nested.plan.json"

            result = invoke(
                "plan",
                "--workspace",
                str(workspace),
                "--run-id",
                "nested-output",
                "--model",
                str(model),
                "--recipe",
                str(recipe_path),
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("inside the exact parent", result.stderr)
            self.assertFalse(plan_path.exists())
            self.assertFalse((workspace / "nested-output").exists())

    def test_future_real_recipe_schema_maps_to_protocol_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            recipe = canonical_recipe(model)
            recipe["schema_version"] = 2
            recipe_path = base / "future-recipe.json"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "future-recipe",
                "--model",
                str(model),
                "--recipe",
                str(recipe_path),
            )

            self.assertEqual(result.returncode, 4)
            self.assertEqual(result.stdout, "")
            self.assertIn("protocol error", result.stderr)

    def test_malformed_real_recipe_fields_ranges_duplicates_and_parent_mismatch_are_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "model"
            cases: dict[str, dict] = {}
            unknown = canonical_recipe(model)
            unknown["presentation_label"] = "Easy"
            cases["unknown-field"] = unknown
            invalid_range = canonical_recipe(model)
            invalid_range["priorities"]["quality"] = 1.01
            cases["invalid-range"] = invalid_range
            duplicate = canonical_recipe(model)
            duplicate["quant_modes"] = ["mxfp4", "mxfp4"]
            cases["duplicate-mode"] = duplicate
            mismatched = canonical_recipe(model)
            mismatched["exact_parent"] = str((base / "different-model").resolve())
            cases["parent-mismatch"] = mismatched

            for name, recipe in cases.items():
                with self.subTest(name=name):
                    recipe_path = base / f"{name}.json"
                    recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
                    result = invoke(
                        "plan",
                        "--workspace",
                        str(base),
                        "--run-id",
                        name,
                        "--model",
                        str(model),
                        "--recipe",
                        str(recipe_path),
                    )
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_each_uniform_quantization_mode_uses_only_the_frozen_argument_array(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            expected = {
                "mxfp4": ["--q-group-size", "32", "--q-bits", "4"],
                "mxfp8": ["--q-group-size", "32", "--q-bits", "8"],
                "affine": ["--q-group-size", "64", "--q-bits", "4"],
            }
            for mode, precision_arguments in expected.items():
                with self.subTest(mode=mode):
                    plan_path = base / f"{mode}.plan.json"
                    result = invoke(
                        "plan",
                        "--workspace",
                        str(base),
                        "--run-id",
                        f"uniform-{mode}",
                        "--model",
                        str(model),
                        "--operation",
                        "quantize",
                        "--quant-mode",
                        mode,
                        "--target-bpw",
                        "8" if mode == "mxfp8" else "4",
                        "--output",
                        str(plan_path),
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    plan = json.loads(plan_path.read_text(encoding="utf-8"))
                    self.assertEqual(plan["blockers"], [])
                    self.assertEqual(len(plan["steps"]), 1)
                    self.assertEqual(Path(plan["steps"][0]["executable"]), PYTHON)
                    arguments = plan["steps"][0]["arguments"]
                    self.assertEqual(arguments[:3], ["-m", "mlx_lm", "convert"])
                    self.assertEqual(arguments[7:10], ["--quantize", "--q-mode", mode])
                    self.assertEqual(arguments[10:], precision_arguments)

    def test_reviewed_mlx_lm_module_entrypoint_accepts_the_frozen_flags(self) -> None:
        result = subprocess.run(
            [str(PYTHON), "-m", "mlx_lm", "convert", "--help"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--q-group-size", result.stdout)
        self.assertIn("--q-bits", result.stdout)
        self.assertIn("--q-mode", result.stdout)

    def test_executor_accepts_closed_real_plan_and_rejects_recipe_or_resource_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = create_float_model(base)
            plan_path = base / "executor.plan.json"
            planned = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "executor-validation",
                "--model",
                str(model),
                "--operation",
                "quantize",
                "--quant-mode",
                "mxfp4",
                "--output",
                str(plan_path),
            )
            self.assertEqual(planned.returncode, 0, planned.stderr)

            accepted = invoke("run", "--plan", str(plan_path), "--dry-run")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertFalse((base / "executor-validation").exists())

            original = json.loads(plan_path.read_text(encoding="utf-8"))
            tampered_cases = []
            recipe_tampered = json.loads(json.dumps(original))
            recipe_tampered["recipe"]["protection_rules"]["preserve_output_head"] = True
            tampered_cases.append(recipe_tampered)
            resource_tampered = json.loads(json.dumps(original))
            resource_tampered["resource_estimate"]["kind"] = "measured"
            tampered_cases.append(resource_tampered)
            derived_value_tampered = json.loads(json.dumps(original))
            derived_value_tampered["resource_estimate"]["estimated_output_bytes"] += 1
            tampered_cases.append(derived_value_tampered)

            for index, plan in enumerate(tampered_cases):
                with self.subTest(index=index):
                    tampered_path = base / f"tampered-{index}.json"
                    tampered_path.write_text(json.dumps(plan), encoding="utf-8")
                    rejected = invoke("run", "--plan", str(tampered_path), "--dry-run")
                    self.assertEqual(rejected.returncode, 4, rejected.stderr)
                    self.assertFalse((base / "executor-validation").exists())

    def test_float_model_quantization_plan_uses_the_reviewed_mlx_lm_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            model = base / "tiny-llama"
            model.mkdir()
            (model / "config.json").write_text(
                json.dumps(
                    {
                        "model_type": "llama",
                        "architectures": ["LlamaForCausalLM"],
                        "hidden_size": 2,
                        "num_hidden_layers": 1,
                    }
                ),
                encoding="utf-8",
            )
            shard = model / "model-00001-of-00001.safetensors"
            save_file({"model.layers.0.self_attn.o_proj.weight": np.zeros((2, 2), dtype=np.float32)}, shard)
            (model / "model.safetensors.index.json").write_text(
                json.dumps(
                    {"weight_map": {"model.layers.0.self_attn.o_proj.weight": shard.name}}
                ),
                encoding="utf-8",
            )
            plan_path = base / "quantize.plan.json"

            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "quantize-plan",
                "--model",
                str(model),
                "--operation",
                "quantize",
                "--quant-mode",
                "mxfp4",
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(plan_path.read_text())
            self.assertEqual(plan["blockers"], [])
            self.assertEqual(plan["steps"][0]["kind"], "mlx-lm-convert")
            self.assertEqual(Path(plan["steps"][0]["executable"]), PYTHON)
            self.assertEqual(
                plan["steps"][0]["arguments"][0:5],
                ["-m", "mlx_lm", "convert", "--hf-path", str(model.resolve())],
            )

    def test_host_and_failed_inspection_emit_machine_protocol_envelopes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            host_path = base / "host.json"
            host = invoke(
                "host",
                "--workspace",
                str(base),
                "--run-id",
                "host-check",
                "--output",
                str(host_path),
            )
            self.assertEqual(host.returncode, 0, host.stderr)
            host_events = events(host)
            self.assertEqual(host_events[0]["type"], "capability.reported")
            self.assertEqual(host_events[0]["stage"], "host")
            self.assertTrue(host_path.is_file())

            inspected = invoke(
                "inspect",
                "--model",
                str(base / "missing-model"),
                "--run-id",
                "inspect-check",
            )
            self.assertEqual(inspected.returncode, 2, inspected.stderr)
            inspected_events = events(inspected)
            self.assertEqual(inspected_events[0]["type"], "capability.reported")
            self.assertEqual(inspected_events[0]["payload"]["status"], "fail")

    def test_plan_resolves_fixture_recipe_to_an_allowlisted_argument_array(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = base / "plan.json"
            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "fixture-plan",
                "--fixture-scenario",
                "success",
                "--output",
                str(plan_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events(result)[-1]["type"], "plan.ready")
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual(plan["schema_version"], 1)
            self.assertEqual(plan["run_id"], "fixture-plan")
            self.assertEqual(len(plan["steps"]), 1)
            step = plan["steps"][0]
            self.assertEqual(step["kind"], "workflow-fixture")
            self.assertIsInstance(step["executable"], str)
            self.assertIsInstance(step["arguments"], list)
            self.assertNotIn("command", step)

            mixed = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "mixed-fixture-plan",
                "--fixture-scenario",
                "success",
                "--operation",
                "quantize",
            )
            self.assertEqual(mixed.returncode, 2)
            self.assertEqual(mixed.stdout, "")

    def test_recipe_cannot_supply_commands_or_executables(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            recipe = base / "recipe.json"
            recipe.write_text(
                json.dumps({"commands": [{"executable": "/bin/sh", "arguments": ["-c", "id"]}]}),
                encoding="utf-8",
            )
            result = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "unsafe-plan",
                "--recipe",
                str(recipe),
            )

            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("unsupported recipe field", result.stderr)

    def test_commands_keep_exact_arguments_and_a_separately_redacted_display(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "token=ordinary-folder-name"
            base.mkdir()
            plan_path = fixture_plan(base, "fixture-command-record", "success")
            plan = json.loads(plan_path.read_text(encoding="utf-8"))

            result = invoke("run", "--plan", str(plan_path))

            self.assertEqual(result.returncode, 0, result.stderr)
            commands = json.loads(
                (base / "fixture-command-record" / "commands.json").read_text(encoding="utf-8")
            )
            command = commands["commands"][0]
            self.assertEqual(command["arguments"], plan["steps"][0]["arguments"])
            self.assertNotIn("ordinary-folder-name", command["redacted_display"])

    def test_tampered_plan_and_corrupt_journal_map_to_protocol_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-tampered", "success")
            plan = json.loads(plan_path.read_text())
            plan["steps"][0]["executable"] = "/bin/sh"
            plan["steps"][0]["arguments"] = ["-c", "touch escaped"]
            plan_path.write_text(json.dumps(plan), encoding="utf-8")

            tampered = invoke("run", "--plan", str(plan_path))

            self.assertEqual(tampered.returncode, 4)
            self.assertFalse((base / "fixture-tampered").exists())
            self.assertFalse((base / "escaped").exists())

            clean_plan = fixture_plan(base, "fixture-corrupt", "success")
            completed = invoke("run", "--plan", str(clean_plan))
            self.assertEqual(completed.returncode, 0)
            run_dir = base / "fixture-corrupt"
            with (run_dir / "events.jsonl").open("a", encoding="utf-8") as handle:
                handle.write('{"schema_version":1,"run_id":"fixture-corrupt"')
            rejected = invoke("qualify", "--run-dir", str(run_dir))
            self.assertEqual(rejected.returncode, 4)
            self.assertIn("corrupt journal tail", rejected.stderr)

    def test_successful_run_persists_an_atomic_manifest_journal_commands_and_stage_logs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            parent = base / "parent"
            parent.mkdir()
            source = parent / "weights.fixture"
            source.write_bytes(b"immutable-parent")
            before = sha256(source)
            plan_path = base / "fixture-plan.json"
            planned = invoke(
                "plan",
                "--workspace",
                str(base),
                "--run-id",
                "fixture-success",
                "--model",
                str(parent),
                "--fixture-scenario",
                "success",
                "--output",
                str(plan_path),
            )
            self.assertEqual(planned.returncode, 0, planned.stderr)

            result = invoke("run", "--plan", str(plan_path))

            self.assertEqual(result.returncode, 0, result.stderr)
            emitted = events(result)
            self.assertEqual([item["sequence"] for item in emitted], list(range(1, len(emitted) + 1)))
            self.assertEqual(emitted[0]["type"], "run.created")
            self.assertEqual(emitted[-1]["type"], "run.completed")
            run_dir = base / "fixture-success"
            manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["state"], "completed")
            self.assertEqual(manifest["exact_parent"], str(parent.resolve()))
            self.assertEqual(manifest["last_committed_sequence"], len(emitted))
            journal = [json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()]
            self.assertEqual(journal, emitted)
            self.assertEqual(
                terminal_event(journal)["payload"]["resumability"],
                manifest["resumability"],
            )
            self.assertTrue((run_dir / "logs" / "fixture.stdout.log").is_file())
            self.assertTrue((run_dir / "logs" / "fixture.stderr.log").is_file())
            commands = json.loads((run_dir / "commands.json").read_text(encoding="utf-8"))
            self.assertIsInstance(commands["commands"][0]["arguments"], list)
            self.assertEqual(before, sha256(source))

    def test_nonzero_stage_exit_is_journalled_and_maps_to_execution_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-failure", "failure")

            result = invoke("run", "--plan", str(plan_path))

            self.assertEqual(result.returncode, 5, result.stderr)
            emitted = events(result)
            self.assertIn("stage.failed", [item["type"] for item in emitted])
            self.assertEqual(emitted[-1]["type"], "run.state")
            self.assertEqual(emitted[-1]["payload"]["state"], "failed")
            manifest = json.loads((base / "fixture-failure" / "run.json").read_text())
            self.assertEqual(manifest["state"], "failed")
            self.assertEqual(
                terminal_event(emitted)["payload"]["resumability"],
                manifest["resumability"],
            )
            stderr = (base / "fixture-failure" / "logs" / "fixture.stderr.log").read_text()
            self.assertIn("deterministic failure", stderr)

    def test_blocked_plan_never_launches_a_stage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-blocked", "block")

            result = invoke("run", "--plan", str(plan_path))

            self.assertEqual(result.returncode, 3, result.stderr)
            emitted = events(result)
            self.assertEqual(emitted[-1]["type"], "plan.blocked")
            self.assertNotIn("stage.started", [item["type"] for item in emitted])
            manifest = json.loads((base / "fixture-blocked" / "run.json").read_text())
            self.assertEqual(manifest["state"], "blocked")
            self.assertEqual(manifest["child_processes"], [])

    def test_warning_and_stderr_flood_are_streamed_without_deadlock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            warning_plan = fixture_plan(base, "fixture-warning", "warning")
            warning = invoke("run", "--plan", str(warning_plan))
            self.assertEqual(warning.returncode, 0, warning.stderr)
            self.assertIn("warning.raised", [item["type"] for item in events(warning)])
            warning_run = base / "fixture-warning"
            persisted = "\n".join(
                path.read_text(encoding="utf-8", errors="replace")
                for path in warning_run.rglob("*")
                if path.is_file()
            )
            self.assertNotIn("fixture-secret", persisted)
            self.assertIn("<redacted>", persisted)

            flood_plan = fixture_plan(base, "fixture-flood", "stderr-flood")
            flood = invoke("run", "--plan", str(flood_plan))
            self.assertEqual(flood.returncode, 0, flood.stderr)
            flood_events = events(flood)
            stderr_events = [
                item
                for item in flood_events
                if item["type"] == "stage.log" and item["payload"]["stream"] == "stderr"
            ]
            self.assertEqual(len(stderr_events), 256)
            self.assertGreater(
                (base / "fixture-flood" / "logs" / "fixture.stderr.log").stat().st_size,
                1_000_000,
            )

    def test_cooperative_cancellation_marks_and_signals_only_the_recorded_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-cancel", "cancel")
            process = subprocess.Popen(
                [str(PYTHON), str(CLI), "--machine", "run", "--plan", str(plan_path)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert process.stdout is not None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                line = process.stdout.readline()
                if line and json.loads(line)["type"] == "stage.started":
                    break
            else:
                process.kill()
                self.fail("fixture stage did not start")

            cancellation = invoke(
                "cancel-status",
                "--run-dir",
                str(base / "fixture-cancel"),
                "--request",
            )
            self.assertEqual(cancellation.returncode, 0, cancellation.stderr)
            cancellation_status = json.loads(cancellation.stdout)
            self.assertEqual(cancellation_status["kind"], "cancel-status")
            self.assertEqual(cancellation_status["state"], "cancelling")
            self.assertNotIn("sequence", cancellation_status)
            remaining_stdout, stderr = process.communicate(timeout=10)

            self.assertEqual(process.returncode, 6, stderr)
            run_dir = base / "fixture-cancel"
            self.assertTrue((run_dir / "cancel.request.json").is_file())
            manifest = json.loads((run_dir / "run.json").read_text())
            self.assertEqual(manifest["state"], "cancelled")
            self.assertEqual(len(manifest["child_processes"]), 1)
            child = manifest["child_processes"][0]
            self.assertEqual(child["signal"], "SIGTERM")
            journal = [json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()]
            self.assertEqual([item["sequence"] for item in journal], list(range(1, len(journal) + 1)))
            self.assertEqual(journal[-1]["type"], "run.cancelled")
            self.assertEqual(
                terminal_event(journal)["payload"]["resumability"],
                manifest["resumability"],
            )
            self.assertNotIn(
                "cancelling",
                [item["payload"].get("state") for item in journal],
                "the external request must not append an event missing from the live run stream",
            )

    def test_malformed_cancellation_marker_still_records_terminal_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-invalid-cancel-marker", "cancel")
            process = subprocess.Popen(
                [str(PYTHON), str(CLI), "--machine", "run", "--plan", str(plan_path)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert process.stdout is not None
            for _ in range(30):
                line = process.stdout.readline()
                if line and json.loads(line)["type"] == "stage.started":
                    break
            else:
                process.kill()
                self.fail("cancellable fixture did not start")
            run_dir = base / "fixture-invalid-cancel-marker"
            (run_dir / "cancel.request.json").write_text("{}", encoding="utf-8")

            _, stderr = process.communicate(timeout=10)

            self.assertEqual(process.returncode, 6, stderr)
            manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["state"], "cancelled")
            self.assertIn("requested_at", manifest["cancellation"])
            self.assertIn("marker_error", manifest["cancellation"])
            journal = [
                json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()
            ]
            self.assertEqual(journal[-1]["type"], "run.cancelled")

    def test_dry_run_executes_no_stage_and_creates_no_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-dry-run", "success")

            result = invoke("run", "--plan", str(plan_path), "--dry-run")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events(result)[-1]["payload"]["dry_run"], True)
            self.assertFalse((base / "fixture-dry-run").exists())

    def test_run_rejects_plan_bytes_changed_after_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-reviewed-plan", "success")
            reviewed_digest = sha256(plan_path)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            plan["recipe"]["fixture_scenario"] = "warning"
            plan_path.write_text(json.dumps(plan), encoding="utf-8")

            result = invoke(
                "run",
                "--plan",
                str(plan_path),
                "--expected-plan-sha256",
                reviewed_digest,
            )

            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn("plan bytes changed after review", result.stderr)
            self.assertFalse((base / "fixture-reviewed-plan").exists())

    def test_qualification_requires_completed_exact_parent_and_all_required_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            parent = base / "parent"
            parent.mkdir()
            plan_path = fixture_plan(base, "fixture-qualify", "success", model=parent)
            executed = invoke("run", "--plan", str(plan_path))
            self.assertEqual(executed.returncode, 0, executed.stderr)

            qualified = invoke("qualify", "--run-dir", str(base / "fixture-qualify"))

            self.assertEqual(qualified.returncode, 0, qualified.stderr)
            qualified_events = events(qualified)
            self.assertIn("metric.recorded", [item["type"] for item in qualified_events])
            self.assertEqual(qualified_events[-1]["type"], "promotion.gate")
            manifest = json.loads((base / "fixture-qualify" / "run.json").read_text())
            self.assertTrue(manifest["qualified"])

            failed_plan = fixture_plan(base, "fixture-not-qualified", "failure", model=parent)
            failed = invoke("run", "--plan", str(failed_plan))
            self.assertEqual(failed.returncode, 5)
            rejected = invoke("qualify", "--run-dir", str(base / "fixture-not-qualified"))
            self.assertEqual(rejected.returncode, 3)
            failed_manifest = json.loads((base / "fixture-not-qualified" / "run.json").read_text())
            self.assertFalse(failed_manifest["qualified"])

    def test_safe_interruption_resumes_from_the_append_only_journal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-resume", "interrupt-once")
            process = subprocess.Popen(
                [str(PYTHON), str(CLI), "--machine", "run", "--plan", str(plan_path)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert process.stdout is not None
            for _ in range(30):
                line = process.stdout.readline()
                if line and json.loads(line)["type"] == "stage.log":
                    process.send_signal(2)
                    break
            else:
                process.kill()
                self.fail("interruptible fixture did not start")
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 6)
            run_dir = base / "fixture-resume"
            interrupted = json.loads((run_dir / "run.json").read_text())
            self.assertEqual(interrupted["state"], "interrupted")
            self.assertEqual(interrupted["resumability"], "safe")
            interrupted_journal = [
                json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()
            ]
            self.assertEqual(
                terminal_event(interrupted_journal)["payload"]["resumability"],
                interrupted["resumability"],
            )

            resumed = invoke("resume", "--run-dir", str(run_dir))

            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertEqual(events(resumed)[-1]["type"], "run.completed")
            manifest = json.loads((run_dir / "run.json").read_text())
            self.assertEqual(manifest["state"], "completed")
            journal = [json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()]
            self.assertEqual([item["sequence"] for item in journal], list(range(1, len(journal) + 1)))
            self.assertEqual(
                terminal_event(journal)["payload"]["resumability"],
                manifest["resumability"],
            )

    def test_cancelling_a_resumed_step_records_cancelled_terminal_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            plan_path = fixture_plan(base, "fixture-resume-cancel", "interrupt-once")
            initial = subprocess.Popen(
                [str(PYTHON), str(CLI), "--machine", "run", "--plan", str(plan_path)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert initial.stdout is not None
            for _ in range(30):
                line = initial.stdout.readline()
                if line and json.loads(line)["type"] == "stage.log":
                    initial.send_signal(2)
                    break
            else:
                initial.kill()
                self.fail("interruptible fixture did not start")
            initial.communicate(timeout=10)
            self.assertEqual(initial.returncode, 6)

            run_dir = base / "fixture-resume-cancel"
            (run_dir / "artifacts" / ".interrupt-once-started").unlink()
            resumed = subprocess.Popen(
                [str(PYTHON), str(CLI), "--machine", "resume", "--run-dir", str(run_dir)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert resumed.stdout is not None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                line = resumed.stdout.readline()
                if line and json.loads(line)["type"] == "stage.started":
                    break
            else:
                resumed.kill()
                self.fail("resumed fixture stage did not start")

            cancellation = invoke(
                "cancel-status",
                "--run-dir",
                str(run_dir),
                "--request",
            )
            self.assertEqual(cancellation.returncode, 0, cancellation.stderr)
            _, stderr = resumed.communicate(timeout=10)

            self.assertEqual(resumed.returncode, 6, stderr)
            manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["state"], "cancelled")
            self.assertEqual(manifest["terminal_reason"], "cancel-requested")
            self.assertEqual(manifest["cancellation"]["signal"], "SIGTERM")
            self.assertEqual(
                manifest["cancellation"]["affected_pids"],
                [manifest["child_processes"][-1]["pid"]],
            )
            journal = [
                json.loads(line) for line in (run_dir / "events.jsonl").read_text().splitlines()
            ]
            self.assertEqual(journal[-1]["type"], "run.cancelled")
            self.assertNotEqual(journal[-1]["type"], "run.interrupted")


if __name__ == "__main__":
    unittest.main()
