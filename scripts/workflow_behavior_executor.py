"""Strict synchronous executor for reviewed behavior-edit experiment contracts."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, TextIO

from workflow_behavior import (
    APPLY_SCRIPT, CODE_ROOT, DERIVE_SCRIPT, EVAL_SCRIPT, WORKFLOW_PYTHON,
    build_promotion_gate_manifest, sha256,
)
from workflow_protocol import MachineWriter, ProtocolError, atomic_write_json, timestamp


ALLOWED_SCRIPTS = {str(path.resolve()): sha256(path) for path in (DERIVE_SCRIPT, APPLY_SCRIPT, EVAL_SCRIPT)}
StepRunner = Callable[[dict[str, Any], Path, Path], int]


def _validate(contract: dict[str, Any]) -> None:
    if contract.get("schema_version") != 1 or contract.get("experiment_type") != "refusal-direction-behavior-edit":
        raise ProtocolError("behavior contract schema or experiment type is unsupported")
    if contract.get("blockers") or not contract.get("steps"):
        raise ProtocolError("blocked behavior contract cannot execute")
    if Path(str(contract.get("run_directory"))).exists():
        raise ProtocolError("behavior run directory already exists")
    for step in contract["steps"]:
        if not isinstance(step, dict) or set(step) != {
            "id", "kind", "display_name", "executable", "arguments", "working_directory",
            "environment_keys", "resumability", "script_sha256", "evidence_contract",
        }:
            raise ProtocolError("behavior step shape is invalid")
        arguments = step.get("arguments")
        if step.get("executable") != str(WORKFLOW_PYTHON.resolve()) or not isinstance(arguments, list) or not arguments:
            raise ProtocolError("behavior step executable is not allowlisted")
        script = str(Path(arguments[0]).resolve())
        if ALLOWED_SCRIPTS.get(script) != step.get("script_sha256"):
            raise ProtocolError("behavior step script identity or hash changed")
        if Path(str(step.get("working_directory"))).resolve() != CODE_ROOT.resolve():
            raise ProtocolError("behavior step working directory changed")


def _default_runner(step: dict[str, Any], stdout_path: Path, stderr_path: Path) -> int:
    environment = {
        key: __import__("os").environ[key]
        for key in step["environment_keys"]
        if key in __import__("os").environ
    }
    # The packaged runtime is integrity checked. Child Python processes must not
    # create __pycache__ files inside the signed application bundle.
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        completed = subprocess.run(
            [step["executable"], *step["arguments"]],
            cwd=step["working_directory"],
            env=environment,
            stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, check=False,
        )
    return completed.returncode


def _read_evaluation(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"behavior evaluation is missing or invalid: {path}") from exc
    if not isinstance(value, dict) or not isinstance(value.get("summary"), dict):
        raise ProtocolError(f"behavior evaluation has no summary: {path}")
    return value


def _reduce_evidence(contract: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    run_dir = Path(contract["run_directory"])
    evaluations = run_dir / "evaluations"
    parent_tuning = _read_evaluation(evaluations / "parent-tuning.json")
    candidate_tuning = _read_evaluation(evaluations / "candidate-tuning.json")
    parent_heldout = _read_evaluation(evaluations / "parent-heldout.json")
    candidate_heldout = _read_evaluation(evaluations / "candidate-heldout.json")
    promotion = contract["promotion_contract"]

    def reduction(parent: dict[str, Any], candidate: dict[str, Any]) -> float:
        return float(parent["summary"]["refusal_rate"]) - float(candidate["summary"]["refusal_rate"])

    def benign_increase(parent: dict[str, Any], candidate: dict[str, Any]) -> float:
        return float(candidate["summary"]["benign_refusal_rate"]) - float(parent["summary"]["benign_refusal_rate"])

    candidate_path = run_dir / "artifacts" / "behavior-edited-candidate"
    config = json.loads((candidate_path / "config.json").read_text(encoding="utf-8"))
    edit = config.get("behavior_edit", {})
    structural = len(edit.get("edited_modules", [])) == contract["module_contract"]["expected_editable_modules"]
    evidence = {
        "exact_parent": contract["exact_parent"],
        "tuning_sha256": contract["datasets"]["tuning"]["sha256"],
        "held_out_sha256": contract["datasets"]["held_out"]["sha256"],
        "structural_passed": structural,
        "tuning_selection_passed": reduction(parent_tuning, candidate_tuning) >= float(promotion["required_held_out_refusal_rate_reduction"]),
        "held_out_target_passed": reduction(parent_heldout, candidate_heldout) >= float(promotion["required_held_out_refusal_rate_reduction"]),
        "benign_retention_passed": benign_increase(parent_heldout, candidate_heldout) <= float(promotion["allowed_benign_refusal_rate_increase"]),
        # The reviewed evaluator currently skips isolated critical code/tool checks.
        "critical_parity_passed": False,
        "no_loops_or_template_drift": False,
        "per_format_parent_parity_passed": False,
    }
    categories = [
        {
            "name": "Held-out refusal prompts",
            "parent_rate": parent_heldout["summary"]["refusal_rate"],
            "candidate_rate": candidate_heldout["summary"]["refusal_rate"],
            "sample_count": len(parent_heldout.get("refusal", [])),
        },
        {
            "name": "Benign controls",
            "parent_rate": parent_heldout["summary"]["benign_refusal_rate"],
            "candidate_rate": candidate_heldout["summary"]["benign_refusal_rate"],
            "sample_count": len(parent_heldout.get("benign_sensitive", [])),
        },
    ]
    return evidence, categories


def execute_behavior_contract(
    contract: dict[str, Any], stream: TextIO = sys.stdout, runner: StepRunner = _default_runner
) -> int:
    _validate(contract)
    run_dir = Path(contract["run_directory"])
    (run_dir / "logs").mkdir(parents=True)
    (run_dir / "artifacts").mkdir()
    (run_dir / "evaluations").mkdir()
    atomic_write_json(run_dir / "contract.json", contract)
    writer = MachineWriter(contract["run_id"], stream)
    writer.emit("run.created", "behavior", {"state": "created", "run_directory": str(run_dir)})
    writer.emit("run.state", "behavior", {"state": "running"})
    for index, step in enumerate(contract["steps"], start=1):
        writer.emit("stage.started", step["id"], {"display_name": step["display_name"]})
        stdout_path = run_dir / "logs" / f"{index:02d}-{step['id']}.stdout.log"
        stderr_path = run_dir / "logs" / f"{index:02d}-{step['id']}.stderr.log"
        code = runner(step, stdout_path, stderr_path)
        if code != 0:
            result = {"schema_version": 1, "state": "failed", "failed_step": step["id"], "exit_code": code, "updated_at": timestamp()}
            atomic_write_json(run_dir / "result.json", result)
            writer.emit("stage.failed", step["id"], result)
            writer.emit("run.state", "behavior", {"state": "failed", "reason": f"{step['id']} exited {code}"})
            return 5
        writer.emit("stage.completed", step["id"], {"exit_code": 0})
    evidence, categories = _reduce_evidence(contract)
    gates = build_promotion_gate_manifest(contract, evidence)
    result = {
        "schema_version": 1, "state": "completed", "qualified": gates["promotion_allowed"],
        "classification": gates["candidate_classification"], "evidence": evidence,
        "categories": categories, "gate_manifest": gates, "updated_at": timestamp(),
    }
    atomic_write_json(run_dir / "result.json", result)
    writer.emit("evaluation.recorded", "behavior-held-out", {"categories": categories, "gates": gates})
    writer.emit("run.completed", "behavior", {"state": "completed", "qualified": gates["promotion_allowed"]})
    return 0
