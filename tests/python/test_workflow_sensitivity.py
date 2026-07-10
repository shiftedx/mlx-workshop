from __future__ import annotations

import json
import sys
import unittest
from dataclasses import replace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from workflow_sensitivity import (  # noqa: E402
    CalibrationContract,
    EvaluationObservation,
    ModuleIdentifier,
    ModuleSpec,
    PrecisionSpec,
    ProtectionRule,
    RuntimeAssignmentSupport,
    SearchPolicy,
    SensitivityRequest,
    analyze_sensitivity,
)


FIXTURE = ROOT / "tests" / "fixtures" / "sensitivity" / "tiny_dense.json"


class FixtureEvaluator:
    evaluator_id = "deterministic-fixture-v1"
    metric_name = "fixture_loss_delta"
    delta_semantics = "increase-is-worse"

    def __init__(self, measurements: dict[str, dict[str, float]]) -> None:
        self.measurements = measurements

    def measure(self, module, precision, calibration):
        delta = self.measurements.get(module.identifier.canonical, {}).get(precision.identifier)
        if delta is None:
            return None
        return EvaluationObservation(
            delta=delta,
            sample_count=calibration.sample_budget,
            token_count=calibration.token_budget,
            evidence_ref=f"fixture://{module.identifier.canonical}/{precision.identifier}",
        )


class OverBudgetEvaluator(FixtureEvaluator):
    def measure(self, module, precision, calibration):
        observation = super().measure(module, precision, calibration)
        if observation is None:
            return None
        return replace(observation, token_count=calibration.token_budget + 1)


def fixture_request(data: dict) -> SensitivityRequest:
    calibration = CalibrationContract(**data["calibration"])
    modules = tuple(
        ModuleSpec(
            identifier=ModuleIdentifier.parse(item["id"]),
            parameter_count=item["parameters"],
            input_features=item["input_features"],
        )
        for item in data["modules"]
    )
    reference = PrecisionSpec(
        identifier="fp16",
        mode="float",
        bits=16,
        group_size=None,
        bytes_per_group_overhead=0,
        size_model="dense-bits-v1",
    )
    trials = (
        PrecisionSpec("mxfp4", "mxfp4", 4, 32, 1, "mlx-packed-groups-v1"),
        PrecisionSpec("mxfp8", "mxfp8", 8, 32, 1, "mlx-packed-groups-v1"),
    )
    return SensitivityRequest(
        modules=modules,
        calibration=calibration,
        reference_precision=reference,
        trial_precisions=trials,
        runtime=RuntimeAssignmentSupport(
            runtime_id="mlx-lm-fixture",
            supported_modes=("mxfp4", "mxfp8"),
            supports_per_module_parameters=True,
            supports_mixed_modes=True,
            supports_float_fallback=True,
        ),
        protection_rules=(
            ProtectionRule("terminal-weights", roles=("embedding", "lm_head")),
        ),
        search=SearchPolicy(max_search_states=64, max_predicted_metric_delta=0.20),
        fixed_bytes=100,
    )


class WorkflowSensitivityTests(unittest.TestCase):
    def test_fixture_measurements_produce_stable_protected_pareto_assignments(self) -> None:
        data = json.loads(FIXTURE.read_text(encoding="utf-8"))
        request = fixture_request(data)
        evaluator = FixtureEvaluator(data["measurements"])

        first = analyze_sensitivity(request, evaluator)
        second = analyze_sensitivity(
            replace(
                request,
                modules=tuple(reversed(request.modules)),
                trial_precisions=tuple(reversed(request.trial_precisions)),
            ),
            evaluator,
        )

        self.assertEqual(first.status, "supported")
        self.assertEqual(first, second)
        self.assertEqual(first.calibration, request.calibration)
        self.assertEqual(first.runtime_id, request.runtime.runtime_id)
        self.assertEqual(len(first.measurements), 6)
        self.assertTrue(
            all(
                measurement.sample_count <= request.calibration.sample_budget
                and measurement.token_count <= request.calibration.token_budget
                for measurement in first.measurements
            )
        )
        self.assertTrue(first.frontier)
        for candidate in first.candidates:
            assignments = dict(candidate.assignments)
            self.assertEqual(assignments["global.embedding"], "fp16")
            self.assertEqual(assignments["global.lm_head"], "fp16")
            self.assertLessEqual(candidate.predicted_metric_delta, 0.20)
        for candidate in first.frontier:
            self.assertIn(candidate, first.candidates)

    def test_size_prediction_and_group_ineligibility_match_mlx_quantize_structure(self) -> None:
        data = json.loads(FIXTURE.read_text(encoding="utf-8"))
        request = fixture_request(data)
        ineligible = ModuleSpec(
            identifier=ModuleIdentifier.parse("layer.2.mlp.down"),
            parameter_count=480,
            input_features=24,
        )
        request = replace(request, modules=(*request.modules, ineligible))

        result = analyze_sensitivity(request, FixtureEvaluator(data["measurements"]))

        self.assertEqual(result.status, "supported")
        reference = next(
            candidate
            for candidate in result.candidates
            if all(precision == "fp16" for _module, precision in candidate.assignments)
        )
        self.assertEqual(reference.predicted_bytes, 100 + (10_496 + 480) * 2)
        for candidate in result.candidates:
            self.assertEqual(dict(candidate.assignments)["layer.2.mlp.down"], "fp16")

    def test_declared_search_and_calibration_budgets_fail_closed(self) -> None:
        data = json.loads(FIXTURE.read_text(encoding="utf-8"))
        request = fixture_request(data)
        evaluator = FixtureEvaluator(data["measurements"])

        search_limited = analyze_sensitivity(
            replace(request, search=replace(request.search, max_search_states=8)),
            evaluator,
        )
        evidence_over_budget = analyze_sensitivity(
            request,
            OverBudgetEvaluator(data["measurements"]),
        )

        self.assertEqual(search_limited.status, "unsupported")
        self.assertEqual(search_limited.unsupported.code, "search-budget-exceeded")
        self.assertEqual(evidence_over_budget.status, "unsupported")
        self.assertEqual(evidence_over_budget.unsupported.code, "evaluator-evidence-invalid")
        self.assertFalse(evidence_over_budget.measurements)

    def test_missing_evidence_and_unexpressible_runtime_return_explicit_unsupported(self) -> None:
        data = json.loads(FIXTURE.read_text(encoding="utf-8"))
        request = fixture_request(data)

        no_evaluator = analyze_sensitivity(request, None)
        missing_evidence = analyze_sensitivity(request, FixtureEvaluator({}))
        no_assignments = analyze_sensitivity(
            replace(
                request,
                runtime=replace(request.runtime, supports_per_module_parameters=False),
            ),
            FixtureEvaluator(data["measurements"]),
        )
        unsupported_mode = analyze_sensitivity(
            replace(request, runtime=replace(request.runtime, supported_modes=("mxfp4",))),
            FixtureEvaluator(data["measurements"]),
        )

        self.assertEqual(no_evaluator.unsupported.code, "evaluator-unavailable")
        self.assertEqual(missing_evidence.unsupported.code, "evaluator-evidence-missing")
        self.assertEqual(no_assignments.unsupported.code, "per-module-assignments-unsupported")
        self.assertEqual(unsupported_mode.unsupported.code, "precision-mode-unsupported")
        for result in (no_evaluator, missing_evidence, no_assignments, unsupported_mode):
            self.assertEqual(result.status, "unsupported")
            self.assertEqual(result.calibration, request.calibration)
            self.assertEqual(result.runtime_id, request.runtime.runtime_id)
            self.assertFalse(result.measurements)
            self.assertFalse(result.candidates)


if __name__ == "__main__":
    unittest.main()
