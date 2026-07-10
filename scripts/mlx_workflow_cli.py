#!/usr/bin/env python3
"""Versioned local protocol driver for MLX Workshop."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from workflow_executor import qualify_run, resume_run, run_plan
from workflow_host import snapshot_host
from workflow_plan import FIXTURE_SCENARIOS, resolve_plan
from workflow_promotion import PromotionError, qualified_run_evidence, stage_qualified_run
from workflow_protocol import (
    MachineWriter,
    ProtocolError,
    WorkflowInputError,
    atomic_write_json,
    read_object,
)


EXIT_SUCCESS = 0
EXIT_INVALID = 2
EXIT_BLOCKED = 3
EXIT_PROTOCOL = 4
EXIT_EXECUTION = 5
EXIT_CANCELLED = 6


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--machine", action="store_true")
    subparsers = parser.add_subparsers(dest="command", required=True)

    host = subparsers.add_parser("host")
    host.add_argument("--workspace", type=Path, required=True)
    host.add_argument("--run-id", default="host-snapshot")
    host.add_argument("--output", type=Path)

    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("--model", type=Path, required=True)
    inspect.add_argument("--run-id", default="inspect-model")
    inspect.add_argument("--output", type=Path)

    plan = subparsers.add_parser("plan")
    plan.add_argument("--workspace", type=Path, required=True)
    plan.add_argument("--run-id", required=True)
    plan.add_argument("--model", type=Path)
    plan.add_argument("--recipe", type=Path)
    plan.add_argument("--operation", action="append")
    plan.add_argument("--quant-mode", action="append")
    plan.add_argument("--allocation-strategy")
    plan.add_argument("--target-bpw", type=float)
    plan.add_argument("--kl-tolerance", type=float)
    plan.add_argument("--per-module-overrides", action="store_true", default=None)
    plan.add_argument("--quality-priority", type=float)
    plan.add_argument("--size-priority", type=float)
    plan.add_argument("--time-budget-seconds", type=int)
    plan.add_argument("--context-target-tokens", type=int)
    plan.add_argument("--calibration-identity")
    plan.add_argument("--calibration-dataset-sha256")
    plan.add_argument("--calibration-sample-budget", type=int)
    plan.add_argument("--calibration-token-budget", type=int)
    plan.add_argument("--calibration-seed", type=int)
    plan.add_argument("--preserve-embeddings", action="store_true", default=None)
    plan.add_argument("--preserve-output-head", action="store_true", default=None)
    plan.add_argument("--protect-sensitive-modules", action="store_true", default=None)
    plan.add_argument("--fixture-scenario", choices=sorted(FIXTURE_SCENARIOS))
    plan.add_argument("--output", type=Path)

    run = subparsers.add_parser("run")
    run.add_argument("--plan", type=Path, required=True)
    run.add_argument("--expected-plan-sha256")
    run.add_argument("--dry-run", action="store_true")

    resume = subparsers.add_parser("resume")
    resume.add_argument("--run-dir", type=Path, required=True)

    qualify = subparsers.add_parser("qualify")
    qualify.add_argument("--run-dir", type=Path, required=True)

    stage = subparsers.add_parser("stage")
    stage.add_argument("--run-dir", type=Path, required=True)
    stage.add_argument("--staging-root", type=Path, required=True)
    stage.add_argument("--stage-id", required=True)

    evidence = subparsers.add_parser("evidence")
    evidence.add_argument("--run-dir", type=Path, required=True)

    sensitivity = subparsers.add_parser("sensitivity")
    sensitivity.add_argument("--model", type=Path, required=True)
    sensitivity.add_argument("--workspace", type=Path, required=True)
    sensitivity.add_argument("--run-id", required=True)
    sensitivity.add_argument("--max-kl", type=float, default=0.20)
    sensitivity.add_argument("--output", type=Path)

    materialize = subparsers.add_parser("materialize-mixed")
    materialize.add_argument("--analysis", type=Path, required=True)
    materialize.add_argument("--candidate-id", required=True)
    materialize.add_argument("--output", type=Path, required=True)
    materialize.add_argument("--run-id", default="materialize-mixed")

    behavior_plan = subparsers.add_parser("behavior-plan")
    behavior_plan.add_argument("--model", type=Path, required=True)
    behavior_plan.add_argument("--workspace", type=Path, required=True)
    behavior_plan.add_argument("--run-id", required=True)
    behavior_plan.add_argument("--output", type=Path)

    behavior_run = subparsers.add_parser("behavior-run")
    behavior_run.add_argument("--contract", type=Path, required=True)

    mtp_inspect = subparsers.add_parser("mtp-inspect")
    mtp_inspect.add_argument("--model", type=Path, required=True)
    mtp_inspect.add_argument("--run-id", default="mtp-inspect")

    vision_smoke = subparsers.add_parser("vision-smoke")
    vision_smoke.add_argument("--model", type=Path, required=True)
    vision_smoke.add_argument("--image", type=Path, required=True)
    vision_smoke.add_argument("--workspace", type=Path, required=True)
    vision_smoke.add_argument("--run-id", required=True)
    vision_smoke.add_argument("--prompt", default="Describe this image briefly and precisely.")

    cancel_status = subparsers.add_parser("cancel-status")
    cancel_status.add_argument("--run-dir", type=Path, required=True)
    cancel_status.add_argument("--request", action="store_true")
    return parser


def recipe_from_arguments(args: argparse.Namespace) -> dict:
    real_inline_values = (
        args.operation,
        args.quant_mode,
        args.allocation_strategy,
        args.target_bpw,
        args.kl_tolerance,
        args.per_module_overrides,
        args.quality_priority,
        args.size_priority,
        args.time_budget_seconds,
        args.context_target_tokens,
        args.calibration_identity,
        args.calibration_dataset_sha256,
        args.calibration_sample_budget,
        args.calibration_token_budget,
        args.calibration_seed,
        args.preserve_embeddings,
        args.preserve_output_head,
        args.protect_sensitive_modules,
    )
    if args.recipe:
        if args.fixture_scenario is not None or any(
            value is not None for value in real_inline_values
        ):
            raise WorkflowInputError("--recipe cannot be combined with inline recipe options")
        return read_object(args.recipe)
    if args.fixture_scenario:
        if any(value is not None for value in real_inline_values):
            raise WorkflowInputError(
                "--fixture-scenario cannot be combined with real recipe options"
            )
        return {"fixture_scenario": args.fixture_scenario}
    exact_parent = str(args.model.expanduser().resolve()) if args.model else None
    return {
        "schema_version": 1,
        "exact_parent": exact_parent,
        "operations": args.operation or [],
        "quant_modes": args.quant_mode or ["mxfp4"],
        "allocation": {
            "strategy": args.allocation_strategy or "uniform",
            "target_bpw": args.target_bpw if args.target_bpw is not None else 4.0,
            "kl_tolerance": args.kl_tolerance,
            "per_module_overrides": args.per_module_overrides or False,
        },
        "priorities": {
            "quality": args.quality_priority if args.quality_priority is not None else 0.78,
            "size": args.size_priority if args.size_priority is not None else 0.58,
        },
        "time_budget_seconds": (
            args.time_budget_seconds if args.time_budget_seconds is not None else 3600
        ),
        "context_target_tokens": (
            args.context_target_tokens if args.context_target_tokens is not None else 32768
        ),
        "calibration": {
            "identity": args.calibration_identity or "not-applicable",
            "dataset_sha256": args.calibration_dataset_sha256,
            "sample_budget": (
                args.calibration_sample_budget
                if args.calibration_sample_budget is not None
                else 0
            ),
            "token_budget": (
                args.calibration_token_budget if args.calibration_token_budget is not None else 0
            ),
            "seed": args.calibration_seed,
        },
        "protection_rules": {
            "preserve_embeddings": args.preserve_embeddings or False,
            "preserve_output_head": args.preserve_output_head or False,
            "protect_sensitive_modules": args.protect_sensitive_modules or False,
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


def read_reviewed_plan(path: Path, expected_sha256: str | None) -> dict:
    try:
        data = path.expanduser().resolve().read_bytes()
    except OSError as exc:
        raise WorkflowInputError(f"cannot read plan: {exc}") from exc
    if expected_sha256 is not None:
        if len(expected_sha256) != 64 or any(
            character not in "0123456789abcdefABCDEF" for character in expected_sha256
        ):
            raise WorkflowInputError("--expected-plan-sha256 must be a 64-character hex digest")
        actual_sha256 = hashlib.sha256(data).hexdigest()
        if actual_sha256 != expected_sha256.lower():
            raise ProtocolError("plan bytes changed after review")
    try:
        plan = json.loads(data)
    except json.JSONDecodeError as exc:
        raise WorkflowInputError(f"invalid plan JSON: {exc}") from exc
    if not isinstance(plan, dict):
        raise WorkflowInputError("plan must be a JSON object")
    return plan


def command_plan(args: argparse.Namespace) -> int:
    recipe = recipe_from_arguments(args)
    plan, capabilities = resolve_plan(
        workspace=args.workspace,
        run_id=args.run_id,
        model=args.model,
        recipe=recipe,
    )
    if args.output:
        atomic_write_json(args.output.expanduser().resolve(), plan)
    if args.machine:
        writer = MachineWriter(args.run_id, sys.stdout)
        if capabilities is not None:
            writer.emit("capability.reported", "inspect", capabilities)
        event_type = "plan.blocked" if plan["blockers"] else "plan.ready"
        writer.emit(
            event_type,
            "plan",
            {
                "state": "blocked" if plan["blockers"] else "planned",
                "step_count": len(plan["steps"]),
                "blockers": plan["blockers"],
                "plan": plan,
            },
        )
    else:
        print(json.dumps(plan, indent=2))
    return EXIT_BLOCKED if plan["blockers"] else EXIT_SUCCESS


def output_payload(
    args: argparse.Namespace,
    *, event_type: str,
    stage: str,
    payload: dict,
) -> None:
    if args.output:
        atomic_write_json(args.output.expanduser().resolve(), payload)
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit(event_type, stage, payload)
    else:
        print(json.dumps(payload, indent=2))


def command_cancel_status(args: argparse.Namespace) -> int:
    from workflow_executor import CANCELLATION_GRACE_SECONDS
    from workflow_protocol import timestamp

    run_dir = args.run_dir.expanduser().resolve()
    manifest = read_object(run_dir / "run.json")
    if manifest.get("schema_version") != 1:
        raise ProtocolError("run manifest schema_version is not supported")
    if args.request:
        if manifest.get("state") not in {"running", "cancelling"}:
            raise WorkflowInputError("cancellation can be requested only for a running run")
        marker = {
            "requested_at": timestamp(),
            "requested_by_pid": __import__("os").getpid(),
            "grace_seconds": CANCELLATION_GRACE_SECONDS,
        }
        atomic_write_json(run_dir / "cancel.request.json", marker)
        payload = {"state": "cancelling", **marker}
    else:
        marker_path = run_dir / "cancel.request.json"
        cancellation = manifest.get("cancellation")
        state = manifest.get("state")
        if marker_path.is_file() and state == "running":
            state = "cancelling"
            try:
                cancellation = read_object(marker_path)
            except (ProtocolError, WorkflowInputError):
                cancellation = {"status": "marker-present-but-invalid"}
        payload = {
            "state": state,
            "cancellation": cancellation,
        }
    if args.machine:
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "cancel-status",
                    "run_id": manifest["run_id"],
                    **payload,
                },
                separators=(",", ":"),
            )
        )
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS


def command_stage(args: argparse.Namespace) -> int:
    stage, qualification = stage_qualified_run(
        run_dir=args.run_dir,
        staging_root=args.staging_root,
        stage_id=args.stage_id,
    )
    run_id = args.run_dir.expanduser().resolve().name
    payload = {
        "kind": "staged-candidate",
        "relative_path": stage.name,
        "staging_directory": str(stage),
        "classification": qualification["classification"],
        "qualified": qualification["qualified"],
    }
    if args.machine:
        MachineWriter(run_id, sys.stdout).emit("artifact.discovered", "stage", payload)
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS


def command_evidence(args: argparse.Namespace) -> int:
    payload = qualified_run_evidence(run_dir=args.run_dir)
    if args.machine:
        MachineWriter(payload["run_id"], sys.stdout).emit(
            "evaluation.recorded", "compare", payload
        )
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS


def command_sensitivity(args: argparse.Namespace) -> int:
    from mlx_lm import load
    from workflow_mixed_precision import (
        MLXLayerAdapter,
        MLXLogitsKLEvaluator,
        build_sensitivity_request,
    )
    from workflow_sensitivity import analyze_sensitivity

    with contextlib.redirect_stdout(sys.stderr):
        model = args.model.expanduser().resolve()
        workspace = args.workspace.expanduser().resolve()
        _model, tokenizer = load(str(model), lazy=True)
        prompts = ("A small local model should", "Return valid JSON with one key")
        token_batches = tuple(tuple(tokenizer.encode(prompt)[:64]) for prompt in prompts)
        if any(not batch for batch in token_batches):
            raise WorkflowInputError("the tokenizer produced an empty calibration batch")
        analysis_dir = workspace / ".analyses" / args.run_id
        adapter = MLXLayerAdapter.inspect(model)
        evaluator = MLXLogitsKLEvaluator(
            model_path=model,
            token_batches=token_batches,
            evidence_dir=analysis_dir / "measurements",
        )
        request = build_sensitivity_request(
            adapter=adapter,
            model_path=model,
            token_batches=token_batches,
            max_search_states=max(1, 3 ** len(adapter.modules)),
            max_metric_delta=args.max_kl,
        )
        result = analyze_sensitivity(request, evaluator)
    document = {
        "schema_version": 1,
        "run_id": args.run_id,
        "exact_parent": str(model),
        "analysis": result.to_dict(),
        "recommended_candidate_id": (
            result.frontier[0].candidate_id if result.frontier else None
        ),
    }
    output = args.output.expanduser().resolve() if args.output else analysis_dir / "sensitivity.json"
    atomic_write_json(output, document)
    payload = {**document, "analysis_path": str(output)}
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit("evaluation.recorded", "sensitivity", payload)
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS if result.status == "supported" else EXIT_BLOCKED


def command_materialize_mixed(args: argparse.Namespace) -> int:
    from workflow_mixed_precision import MLXLayerAdapter, apply_assignment

    document = read_object(args.analysis.expanduser().resolve())
    if document.get("schema_version") != 1 or not isinstance(document.get("exact_parent"), str):
        raise WorkflowInputError("mixed-precision analysis is invalid")
    analysis = document.get("analysis")
    candidates = analysis.get("candidates") if isinstance(analysis, dict) else None
    if not isinstance(candidates, list):
        raise WorkflowInputError("mixed-precision candidate evidence is missing")
    selected = next(
        (item for item in candidates if isinstance(item, dict) and item.get("candidate_id") == args.candidate_id),
        None,
    )
    if selected is None or not isinstance(selected.get("assignments"), list):
        raise WorkflowInputError("the selected mixed-precision candidate was not measured")
    assignments = {}
    for item in selected["assignments"]:
        if not isinstance(item, list) or len(item) != 2 or not all(isinstance(value, str) for value in item):
            raise WorkflowInputError("the selected assignment shape is invalid")
        assignments[item[0]] = item[1]
    parent = Path(document["exact_parent"]).resolve()
    with contextlib.redirect_stdout(sys.stderr):
        manifest = apply_assignment(
            model_path=parent,
            output_path=args.output,
            adapter=MLXLayerAdapter.inspect(parent),
            assignments=assignments,
        )
    payload = {
        "kind": "mixed-precision-model",
        "candidate_id": args.candidate_id,
        "candidate": str(args.output.expanduser().resolve()),
        "assignment_manifest": manifest,
    }
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit("artifact.discovered", "materialize-mixed", payload)
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS


def command_behavior_plan(args: argparse.Namespace) -> int:
    from inspect_mlx_model import inspect_model
    from workflow_behavior import resolve_behavior_experiment, write_starter_behavior_recipe

    workspace = args.workspace.expanduser().resolve()
    capabilities = inspect_model(args.model)
    inputs = workspace / ".behavior-inputs" / args.run_id
    try:
        recipe_path = write_starter_behavior_recipe(
            capabilities=capabilities, destination=inputs
        )
        recipe = read_object(recipe_path)
    except ValueError as exc:
        payload = {
            "schema_version": 1,
            "run_id": args.run_id,
            "exact_parent": str(args.model.expanduser().resolve()),
            "blockers": [{"code": "behavior-adapter-required", "message": str(exc)}],
            "steps": [],
        }
    else:
        payload = resolve_behavior_experiment(
            capabilities=capabilities, recipe=recipe, workspace=workspace, run_id=args.run_id
        )
        payload["recipe_path"] = str(recipe_path)
    output = args.output.expanduser().resolve() if args.output else inputs / "contract.json"
    atomic_write_json(output, payload)
    event_type = "plan.blocked" if payload.get("blockers") else "plan.ready"
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit(
            event_type, "behavior-plan", {
                **payload,
                "state": "blocked" if payload.get("blockers") else "planned",
                "contract_path": str(output),
            }
        )
    else:
        print(json.dumps({**payload, "contract_path": str(output)}, indent=2))
    return EXIT_BLOCKED if payload.get("blockers") else EXIT_SUCCESS


def command_mtp_inspect(args: argparse.Namespace) -> int:
    executable = shutil.which("mtplx")
    if executable is None:
        for candidate in (
            Path.home() / ".local/bin/mtplx",
            Path("/opt/homebrew/bin/mtplx"),
            Path("/usr/local/bin/mtplx"),
        ):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                executable = str(candidate)
                break
    if executable is None:
        raise WorkflowInputError("MTPLX is not installed on this Mac")
    completed = subprocess.run(
        [executable, "inspect", "--model", str(args.model.expanduser().resolve()), "--require-mtp", "--json"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=60, check=False,
    )
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise WorkflowInputError(f"MTPLX did not return JSON: {completed.stderr.strip()}") from exc
    compatibility = report.get("compatibility", {})
    supported = compatibility.get("supported") is True and compatibility.get("can_run") is True
    payload = {"supported": supported, "report": report}
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit("capability.reported", "mtp-inspect", payload)
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS if supported else EXIT_BLOCKED


def command_vision_smoke(args: argparse.Namespace) -> int:
    from inspect_mlx_model import inspect_model

    model = args.model.expanduser().resolve()
    image = args.image.expanduser().resolve()
    if not image.is_file():
        raise WorkflowInputError(f"vision input is not a file: {image}")
    capabilities = inspect_model(model)
    if capabilities.get("capabilities", {}).get("vision") is not True:
        payload = {
            "state": "blocked", "supported": False,
            "reason": "The inspected model does not advertise vision weights.",
        }
        if args.machine:
            MachineWriter(args.run_id, sys.stdout).emit("plan.blocked", "vision-smoke", payload)
        else:
            print(json.dumps(payload, indent=2))
        return EXIT_BLOCKED
    evidence_dir = args.workspace.expanduser().resolve() / ".extension-checks" / args.run_id
    evidence_dir.mkdir(parents=True, exist_ok=False)
    completed = subprocess.run(
        [
            sys.executable, "-m", "mlx_vlm.generate", "--model", str(model),
            "--image", str(image), "--prompt", args.prompt,
            "--max-tokens", "64", "--no-verbose",
        ],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=900, check=False,
    )
    (evidence_dir / "stdout.log").write_text(completed.stdout, encoding="utf-8")
    (evidence_dir / "stderr.log").write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        payload = {"state": "failed", "supported": True, "exit_code": completed.returncode, "evidence_directory": str(evidence_dir)}
        event_type = "stage.failed"
    else:
        payload = {
            "state": "completed", "supported": True, "response": completed.stdout.strip(),
            "image": str(image), "exact_parent": str(model), "evidence_directory": str(evidence_dir),
        }
        event_type = "evaluation.recorded"
    if args.machine:
        MachineWriter(args.run_id, sys.stdout).emit(event_type, "vision-smoke", payload)
    else:
        print(json.dumps(payload, indent=2))
    return EXIT_SUCCESS if completed.returncode == 0 else EXIT_EXECUTION


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "host":
            output_payload(
                args,
                event_type="capability.reported",
                stage="host",
                payload=snapshot_host(args.workspace),
            )
            return EXIT_SUCCESS
        if args.command == "inspect":
            from inspect_mlx_model import inspect_model

            result = inspect_model(args.model)
            output_payload(
                args,
                event_type="capability.reported",
                stage="inspect",
                payload=result,
            )
            return EXIT_SUCCESS if result.get("status") == "pass" else EXIT_INVALID
        if args.command == "plan":
            return command_plan(args)
        if args.command == "run":
            plan = read_reviewed_plan(args.plan, args.expected_plan_sha256)
            return run_plan(plan, sys.stdout, dry_run=args.dry_run)
        if args.command == "resume":
            return resume_run(args.run_dir, sys.stdout)
        if args.command == "qualify":
            return qualify_run(args.run_dir, sys.stdout)
        if args.command == "stage":
            return command_stage(args)
        if args.command == "evidence":
            return command_evidence(args)
        if args.command == "sensitivity":
            return command_sensitivity(args)
        if args.command == "materialize-mixed":
            return command_materialize_mixed(args)
        if args.command == "behavior-plan":
            return command_behavior_plan(args)
        if args.command == "behavior-run":
            from workflow_behavior_executor import execute_behavior_contract

            return execute_behavior_contract(read_object(args.contract), sys.stdout)
        if args.command == "mtp-inspect":
            return command_mtp_inspect(args)
        if args.command == "vision-smoke":
            return command_vision_smoke(args)
        if args.command == "cancel-status":
            return command_cancel_status(args)
    except (WorkflowInputError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except ProtocolError as exc:
        print(f"protocol error: {exc}", file=sys.stderr)
        return EXIT_PROTOCOL
    except PromotionError as exc:
        print(f"blocked: {exc}", file=sys.stderr)
        return EXIT_BLOCKED
    parser.error("unsupported command")
    return EXIT_INVALID


if __name__ == "__main__":
    raise SystemExit(main())
