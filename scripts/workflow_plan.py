"""Resolve closed protocol-v1 recipes into conservative, executable plans."""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path
from typing import Any

from inspect_mlx_model import inspect_model
from workflow_host import snapshot_host
from workflow_protocol import (
    SCHEMA_VERSION,
    ProtocolError,
    WorkflowInputError,
    timestamp,
    validate_run_id,
)


FIXTURE_SCENARIOS = {
    "success",
    "warning",
    "block",
    "failure",
    "stderr-flood",
    "cancel",
    "interrupt-once",
}
CODE_ROOT = Path(__file__).resolve().parents[1]

REAL_RECIPE_FIELDS = {
    "schema_version",
    "exact_parent",
    "operations",
    "quant_modes",
    "allocation",
    "priorities",
    "time_budget_seconds",
    "context_target_tokens",
    "calibration",
    "protection_rules",
    "validation",
}
ALLOCATION_FIELDS = {"strategy", "target_bpw", "kl_tolerance", "per_module_overrides"}
PRIORITY_FIELDS = {"quality", "size"}
CALIBRATION_FIELDS = {
    "identity",
    "dataset_sha256",
    "sample_budget",
    "token_budget",
    "seed",
}
PROTECTION_FIELDS = {
    "preserve_embeddings",
    "preserve_output_head",
    "protect_sensitive_modules",
}
VALIDATION_FIELDS = {"required_gates", "critical_regressions_allowed"}
REQUIRED_GATES = [
    "provenance-structure",
    "deterministic-language-schema",
    "parent-parity",
]
ALLOWED_OPERATIONS = {"quantize", "abliterate", "vision", "mtplx", "benchmark"}
ALLOWED_QUANT_MODES = {"mxfp4", "mxfp8", "affine"}
DISK_RESERVE_BYTES = 30 * 1024**3
MEMORY_RESERVE_BYTES = 8 * 1024**3
OUTPUT_OVERHEAD_BYTES = 64 * 1024**2
TEMPORARY_OVERHEAD_BYTES = 1024**3
PEAK_MEMORY_OVERHEAD_BYTES = 2 * 1024**3
RESOURCE_BASIS = {
    "source": "inspected-safetensors-shard-bytes",
    "output": "quant-mode-factor-plus-64-mib-per-mode",
    "temporary": "source-bytes-plus-1-gib",
    "memory": "source-bytes-plus-2-gib",
    "host": "planning-time-read-only-snapshot",
}
_SHA256 = re.compile(r"[0-9a-fA-F]{64}")


def _require_closed_object(value: Any, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkflowInputError(f"{label} must be an object")
    unknown = set(value) - fields
    missing = fields - set(value)
    if unknown:
        raise WorkflowInputError(f"unsupported {label} field(s): {', '.join(sorted(unknown))}")
    if missing:
        raise WorkflowInputError(f"missing {label} field(s): {', '.join(sorted(missing))}")
    return value


def _require_string_array(value: Any, label: str, allowed: set[str] | None = None) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise WorkflowInputError(f"{label} must be a non-empty array of strings")
    if len(value) != len(set(value)):
        raise WorkflowInputError(f"{label} must not contain duplicates")
    if allowed is not None:
        unknown = sorted(set(value) - allowed)
        if unknown:
            raise WorkflowInputError(f"unsupported {label} value(s): {', '.join(unknown)}")
    return value


def _require_number(
    value: Any, label: str, minimum: float, maximum: float | None = None
) -> float | int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise WorkflowInputError(f"{label} must be a finite number")
    if value < minimum or (maximum is not None and value > maximum):
        raise WorkflowInputError(f"{label} is outside the supported range")
    return value


def _require_integer(
    value: Any, label: str, minimum: int | None = None, maximum: int | None = None
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise WorkflowInputError(f"{label} must be an integer")
    if (minimum is not None and value < minimum) or (
        maximum is not None and value > maximum
    ):
        raise WorkflowInputError(f"{label} is outside the supported range")
    return value


def validate_real_recipe(recipe: dict[str, Any], model: Path) -> dict[str, Any]:
    """Validate one closed real recipe without rewriting any material control."""
    if not isinstance(recipe, dict):
        raise WorkflowInputError("recipe must be an object")
    schema_version = recipe.get("schema_version")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        raise WorkflowInputError("recipe schema_version must be an integer")
    if schema_version > SCHEMA_VERSION:
        raise ProtocolError("recipe schema_version is not supported")
    if schema_version != SCHEMA_VERSION:
        raise WorkflowInputError("recipe schema_version is not supported")
    _require_closed_object(recipe, REAL_RECIPE_FIELDS, "recipe")

    model = model.expanduser().resolve()
    exact_parent = recipe["exact_parent"]
    if not isinstance(exact_parent, str) or not Path(exact_parent).is_absolute():
        raise WorkflowInputError("recipe exact_parent must be an absolute path")
    if exact_parent != str(Path(exact_parent).expanduser().resolve()) or exact_parent != str(model):
        raise WorkflowInputError("recipe exact_parent does not match --model")

    _require_string_array(recipe["operations"], "recipe operations", ALLOWED_OPERATIONS)
    _require_string_array(recipe["quant_modes"], "recipe quant_modes", ALLOWED_QUANT_MODES)

    allocation = _require_closed_object(recipe["allocation"], ALLOCATION_FIELDS, "allocation")
    if allocation["strategy"] not in {"uniform", "mixed-precision"}:
        raise WorkflowInputError("allocation strategy is invalid")
    _require_number(allocation["target_bpw"], "allocation target_bpw", 1.0, 16.0)
    if allocation["kl_tolerance"] is not None:
        _require_number(allocation["kl_tolerance"], "allocation kl_tolerance", 0.0)
    if not isinstance(allocation["per_module_overrides"], bool):
        raise WorkflowInputError("allocation per_module_overrides must be a boolean")

    priorities = _require_closed_object(recipe["priorities"], PRIORITY_FIELDS, "priorities")
    _require_number(priorities["quality"], "quality priority", 0.0, 1.0)
    _require_number(priorities["size"], "size priority", 0.0, 1.0)
    _require_integer(recipe["time_budget_seconds"], "time_budget_seconds", 1)
    _require_integer(recipe["context_target_tokens"], "context_target_tokens", 1)

    calibration = _require_closed_object(
        recipe["calibration"], CALIBRATION_FIELDS, "calibration"
    )
    if not isinstance(calibration["identity"], str) or not calibration["identity"]:
        raise WorkflowInputError("calibration identity must be a non-empty string")
    dataset_sha256 = calibration["dataset_sha256"]
    if dataset_sha256 is not None and (
        not isinstance(dataset_sha256, str) or _SHA256.fullmatch(dataset_sha256) is None
    ):
        raise WorkflowInputError("calibration dataset_sha256 must be a SHA-256 hex digest or null")
    _require_integer(calibration["sample_budget"], "calibration sample_budget", 0)
    _require_integer(calibration["token_budget"], "calibration token_budget", 0)
    if calibration["seed"] is not None:
        _require_integer(calibration["seed"], "calibration seed")

    protection = _require_closed_object(
        recipe["protection_rules"], PROTECTION_FIELDS, "protection_rules"
    )
    if not all(isinstance(protection[field], bool) for field in PROTECTION_FIELDS):
        raise WorkflowInputError("protection rules must be booleans")

    validation = _require_closed_object(recipe["validation"], VALIDATION_FIELDS, "validation")
    _require_string_array(validation["required_gates"], "validation required_gates")
    _require_integer(
        validation["critical_regressions_allowed"],
        "validation critical_regressions_allowed",
        0,
    )
    return recipe


def recipe_control_is_supported(recipe: dict[str, Any]) -> bool:
    """Return whether every material control maps to the reviewed uniform executor."""
    modes = recipe["quant_modes"]
    expected_bpw = {8.0 if mode == "mxfp8" else 4.0 for mode in modes}
    allocation = recipe["allocation"]
    calibration = recipe["calibration"]
    protection = recipe["protection_rules"]
    validation = recipe["validation"]
    return all(
        (
            recipe["operations"] == ["quantize"],
            allocation["strategy"] == "uniform",
            len(expected_bpw) == 1 and float(allocation["target_bpw"]) in expected_bpw,
            allocation["kl_tolerance"] is None,
            allocation["per_module_overrides"] is False,
            calibration
            == {
                "identity": "not-applicable",
                "dataset_sha256": None,
                "sample_budget": 0,
                "token_budget": 0,
                "seed": None,
            },
            not any(protection.values()),
            validation["required_gates"] == REQUIRED_GATES,
            validation["critical_regressions_allowed"] == 0,
        )
    )


def estimate_resources(
    capabilities: dict[str, Any], host: dict[str, Any], recipe: dict[str, Any]
) -> dict[str, Any]:
    """Build the deterministic protocol-v1 conservative resource estimate."""
    source = capabilities.get("source")
    source_bytes = source.get("disk_bytes") if isinstance(source, dict) else None
    if isinstance(source_bytes, bool) or not isinstance(source_bytes, int) or source_bytes <= 0:
        source_bytes = None

    disk = host.get("disk")
    observed_free_disk = disk.get("free_bytes") if isinstance(disk, dict) else None
    if (
        isinstance(observed_free_disk, bool)
        or not isinstance(observed_free_disk, int)
        or observed_free_disk < 0
    ):
        raise WorkflowInputError("host free-disk observation is unavailable")

    hardware = host.get("hardware")
    observed_memory = hardware.get("unified_memory_bytes") if isinstance(hardware, dict) else None
    if isinstance(observed_memory, bool) or not isinstance(observed_memory, int) or observed_memory < 0:
        observed_memory = None
    usable_memory = (
        max(0, observed_memory - MEMORY_RESERVE_BYTES) if observed_memory is not None else None
    )

    reasons = {"duration-estimate-unknown"}
    workloads = host.get("active_workloads")
    if isinstance(workloads, list) and workloads:
        reasons.add("active-workloads-present")
    if observed_memory is None:
        reasons.add("memory-observation-unknown")

    if source_bytes is None:
        estimated_output = None
        estimated_temporary = None
        required_disk = None
        estimated_peak_memory = None
        reasons.add("resource-model-size-unknown")
    else:
        estimated_output = 0
        for mode in recipe["quant_modes"]:
            numerator = 75 if mode == "mxfp8" else 45
            estimated_output += (
                source_bytes * numerator + 99
            ) // 100 + OUTPUT_OVERHEAD_BYTES
        estimated_temporary = source_bytes + TEMPORARY_OVERHEAD_BYTES
        required_disk = estimated_output + estimated_temporary + DISK_RESERVE_BYTES
        estimated_peak_memory = source_bytes + PEAK_MEMORY_OVERHEAD_BYTES
        if required_disk > observed_free_disk:
            reasons.add("resource-disk-insufficient")
        if usable_memory is not None and estimated_peak_memory > usable_memory:
            reasons.add("resource-memory-insufficient")

    if any(reason.startswith("resource-") for reason in reasons):
        feasibility = "blocked"
    elif reasons:
        feasibility = "review-required"
    else:
        feasibility = "feasible"
    return {
        "kind": "estimate",
        "basis": dict(RESOURCE_BASIS),
        "uncertainty": "conservative-upper-bound",
        "source_bytes": source_bytes,
        "estimated_output_bytes": estimated_output,
        "estimated_temporary_bytes": estimated_temporary,
        "disk_reserve_bytes": DISK_RESERVE_BYTES,
        "required_free_disk_bytes": required_disk,
        "observed_free_disk_bytes": observed_free_disk,
        "estimated_peak_memory_bytes": estimated_peak_memory,
        "memory_reserve_bytes": MEMORY_RESERVE_BYTES,
        "observed_unified_memory_bytes": observed_memory,
        "usable_unified_memory_bytes": usable_memory,
        "estimated_duration_seconds": None,
        "time_budget_seconds": recipe["time_budget_seconds"],
        "feasibility": feasibility,
        "reason_codes": sorted(reasons),
    }


def _blocker(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def _fixture_plan(
    workspace: Path, run_id: str, model: Path | None, recipe: dict[str, Any]
) -> tuple[dict[str, Any], None]:
    if set(recipe) != {"fixture_scenario"}:
        unknown = set(recipe) - {"fixture_scenario"}
        if unknown:
            raise WorkflowInputError(f"unsupported recipe field(s): {', '.join(sorted(unknown))}")
        raise WorkflowInputError("fixture recipe shape is invalid")
    fixture_scenario = recipe["fixture_scenario"]
    if fixture_scenario not in FIXTURE_SCENARIOS:
        raise WorkflowInputError("unsupported fixture scenario")
    blockers = (
        [_blocker("fixture-blocked", "Deterministic fixture blocker.")]
        if fixture_scenario == "block"
        else []
    )
    run_dir = workspace / run_id
    helper = CODE_ROOT / "tests" / "helpers" / "workflow_fake_stage.py"
    if not helper.is_file():
        raise WorkflowInputError(f"fixture helper is unavailable: {helper}")
    step = {
        "id": "fixture",
        "kind": "workflow-fixture",
        "display_name": f"Deterministic {fixture_scenario} fixture",
        "executable": str(Path(sys.executable).resolve()),
        "arguments": [
            str(helper.resolve()),
            "--scenario",
            fixture_scenario,
            "--run-dir",
            str(run_dir),
        ],
        "working_directory": str(workspace),
        "environment_keys": ["HOME", "PATH", "TMPDIR"],
        "resumability": "safe" if fixture_scenario in {"cancel", "interrupt-once"} else "unsafe",
    }
    plan = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "created_at": timestamp(),
        "workspace": str(workspace),
        "run_directory": str(run_dir),
        "exact_parent": str(model.expanduser().resolve()) if model else None,
        "capabilities": {},
        "recipe": recipe,
        "blockers": blockers,
        "steps": [] if blockers else [step],
    }
    return plan, None


def resolve_plan(
    *, workspace: Path, run_id: str, model: Path | None, recipe: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    """Resolve a fixture or canonical real recipe through one public planner interface."""
    workspace = workspace.expanduser().resolve()
    if not workspace.is_dir():
        raise WorkflowInputError(f"workspace is not a directory: {workspace}")
    run_id = validate_run_id(run_id)
    if isinstance(recipe, dict) and "fixture_scenario" in recipe:
        return _fixture_plan(workspace, run_id, model, recipe)
    if isinstance(recipe, dict):
        unknown = set(recipe) - REAL_RECIPE_FIELDS
        if unknown:
            raise WorkflowInputError(
                f"unsupported recipe field(s): {', '.join(sorted(unknown))}"
            )
    if model is None:
        raise WorkflowInputError("--model is required for non-fixture plans")
    model = model.expanduser().resolve()
    recipe = validate_real_recipe(recipe, model)
    run_dir = workspace / run_id
    try:
        run_dir.relative_to(model)
    except ValueError:
        pass
    else:
        raise WorkflowInputError("run directory must not be inside the exact parent")
    capabilities = inspect_model(model)
    if capabilities.get("status") != "pass":
        raise WorkflowInputError("model inspection failed")
    host = snapshot_host(workspace)
    resource_estimate = estimate_resources(capabilities, host, recipe)
    blockers: list[dict[str, str]] = []
    if not recipe_control_is_supported(recipe):
        blockers.append(
            _blocker(
                "recipe-control-unsupported",
                "One or more material recipe controls have no reviewed protocol-v1 executor.",
            )
        )
    source = capabilities.get("source")
    routing = capabilities.get("routing")
    conversion = routing.get("conversion") if isinstance(routing, dict) else None
    if (
        not isinstance(source, dict)
        or source.get("state") != "float-candidate"
        or not isinstance(conversion, dict)
        or conversion.get("allowed") is not True
    ):
        blockers.append(
            _blocker(
                "source-state-unsupported",
                "The inspected source is not a reviewed float input for this conversion route.",
            )
        )
    if run_dir.exists():
        blockers.append(
            _blocker("run-directory-exists", "The immutable destination run directory already exists.")
        )
    resource_messages = {
        "resource-model-size-unknown": "The inspected source size is unavailable or zero.",
        "resource-disk-insufficient": "Observed free disk is below output, temporary, and reserve needs.",
        "resource-memory-insufficient": "Estimated peak memory exceeds usable unified memory.",
    }
    for code in resource_estimate["reason_codes"]:
        if code in resource_messages:
            blockers.append(_blocker(code, resource_messages[code]))

    steps: list[dict[str, Any]] = []
    executable = CODE_ROOT / ".venv" / "bin" / "python"
    if not blockers and not executable.is_file():
        blockers.append(
            _blocker("tool-unavailable", f"Required executable is unavailable: {executable}")
        )
    if not blockers:
        for mode in recipe["quant_modes"]:
            group_size = 64 if mode == "affine" else 32
            bits = 8 if mode == "mxfp8" else 4
            output = run_dir / "artifacts" / f"model-{mode}"
            steps.append(
                {
                    "id": f"quantize-{mode}",
                    "kind": "mlx-lm-convert",
                    "display_name": f"Quantize {mode}",
                    "executable": str(executable),
                    "arguments": [
                        "-m",
                        "mlx_lm",
                        "convert",
                        "--hf-path",
                        capabilities["model"],
                        "--mlx-path",
                        str(output),
                        "--quantize",
                        "--q-mode",
                        mode,
                        "--q-group-size",
                        str(group_size),
                        "--q-bits",
                        str(bits),
                    ],
                    "working_directory": str(CODE_ROOT),
                    "environment_keys": ["HOME", "PATH", "TMPDIR"],
                    "resumability": "unsafe",
                }
            )
    plan = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "created_at": timestamp(),
        "workspace": str(workspace),
        "run_directory": str(run_dir),
        "exact_parent": capabilities["model"],
        "capabilities": capabilities,
        "recipe": recipe,
        "resource_estimate": resource_estimate,
        "blockers": blockers,
        "steps": steps,
    }
    return plan, capabilities
