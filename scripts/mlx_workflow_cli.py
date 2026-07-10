#!/usr/bin/env python3
"""Versioned local protocol driver for MLX Workshop."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from workflow_executor import qualify_run, resume_run, run_plan
from workflow_host import snapshot_host
from workflow_plan import FIXTURE_SCENARIOS, resolve_plan
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
        if args.command == "cancel-status":
            return command_cancel_status(args)
    except (WorkflowInputError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except ProtocolError as exc:
        print(f"protocol error: {exc}", file=sys.stderr)
        return EXIT_PROTOCOL
    parser.error("unsupported command")
    return EXIT_INVALID


if __name__ == "__main__":
    raise SystemExit(main())
