"""Safe deterministic protocol-v1 run execution."""

from __future__ import annotations

import hashlib
import fcntl
import importlib.metadata
import json
import os
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, TextIO

from workflow_protocol import (
    SCHEMA_VERSION,
    MachineWriter,
    ProtocolError,
    WorkflowInputError,
    atomic_write_json,
    load_journal,
    timestamp,
    validate_run_id,
)
from workflow_host import snapshot_host
from workflow_promotion import snapshot_artifact
from workflow_plan import (
    DISK_RESERVE_BYTES,
    MEMORY_RESERVE_BYTES,
    OUTPUT_OVERHEAD_BYTES,
    PEAK_MEMORY_OVERHEAD_BYTES,
    RESOURCE_BASIS,
    TEMPORARY_OVERHEAD_BYTES,
    recipe_control_is_supported,
    validate_real_recipe,
)


ALLOWED_ENVIRONMENT_KEYS = frozenset({"HOME", "PATH", "TMPDIR"})
CANCELLATION_GRACE_SECONDS = 2.0
SECRET_KEY = re.compile(r"(?i)(token|secret|password|api[_-]?key|authorization|credential)")
SECRET_TEXT = re.compile(
    r"(?i)(\b(?:token|secret|password|api[_-]?key|authorization|credential)\s*[=:]\s*)([^\s,;]+)"
)
BEARER_TEXT = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(value: str) -> tuple[str, bool]:
    redacted = SECRET_TEXT.sub(r"\1<redacted>", value)
    redacted = BEARER_TEXT.sub("Bearer <redacted>", redacted)
    return redacted, redacted != value


def redact_argument(value: str) -> str:
    redacted, changed = redact_text(value)
    return "<redacted>" if changed or SECRET_KEY.search(value.split("=", 1)[0]) else redacted


class JournalWriter(MachineWriter):
    def __init__(self, run_dir: Path, manifest: dict[str, Any], stream: TextIO) -> None:
        super().__init__(manifest["run_id"], stream, sequence=manifest["last_committed_sequence"])
        self.run_dir = run_dir
        self.manifest = manifest
        self.journal = (run_dir / "events.jsonl").open("a", encoding="utf-8")

    def close(self) -> None:
        self.journal.close()

    def emit(self, event_type: str, stage: str | None, payload: dict[str, Any]) -> dict[str, Any]:
        fcntl.flock(self.journal.fileno(), fcntl.LOCK_EX)
        try:
            try:
                persisted = json.loads((self.run_dir / "run.json").read_text(encoding="utf-8"))
                self.sequence = max(self.sequence, int(persisted["last_committed_sequence"]))
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
                raise ProtocolError(f"cannot synchronize run manifest sequence: {exc}") from exc
            self.sequence += 1
            event = {
                "schema_version": SCHEMA_VERSION,
                "run_id": self.run_id,
                "sequence": self.sequence,
                "timestamp": timestamp(),
                "type": event_type,
                "stage": stage,
                "payload": payload,
            }
            self.journal.write(json.dumps(event, separators=(",", ":")) + "\n")
            self.journal.flush()
            os.fsync(self.journal.fileno())
            self.manifest["last_committed_sequence"] = event["sequence"]
            self.manifest["updated_at"] = event["timestamp"]
            atomic_write_json(self.run_dir / "run.json", self.manifest)
            self.stream.write(json.dumps(event, separators=(",", ":")) + "\n")
            self.stream.flush()
            return event
        finally:
            fcntl.flock(self.journal.fileno(), fcntl.LOCK_UN)


def _require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ProtocolError(f"{label} must be an array of strings")
    return value


RESOURCE_ESTIMATE_FIELDS = {
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
}
RESOURCE_REASON_CODES = {
    "duration-estimate-unknown",
    "active-workloads-present",
    "memory-observation-unknown",
    "resource-model-size-unknown",
    "resource-disk-insufficient",
    "resource-memory-insufficient",
}
RESOURCE_BLOCKER_CODES = {
    "resource-model-size-unknown",
    "resource-disk-insufficient",
    "resource-memory-insufficient",
}
REAL_BLOCKER_CODES = RESOURCE_BLOCKER_CODES | {
    "recipe-control-unsupported",
    "source-state-unsupported",
    "run-directory-exists",
    "tool-unavailable",
}


def _protocol_nonnegative_integer(value: Any, label: str, *, nullable: bool = False) -> int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError(f"{label} must be a non-negative integer")
    return value


def _validate_resource_estimate(
    value: Any, capabilities: dict[str, Any], recipe: dict[str, Any]
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != RESOURCE_ESTIMATE_FIELDS:
        raise ProtocolError("real plan resource_estimate shape is invalid")
    if value["kind"] != "estimate":
        raise ProtocolError("resource estimate kind was modified")
    if value["basis"] != RESOURCE_BASIS or value["uncertainty"] != "conservative-upper-bound":
        raise ProtocolError("resource estimate basis or uncertainty was modified")
    if value["disk_reserve_bytes"] != DISK_RESERVE_BYTES:
        raise ProtocolError("resource disk reserve was modified")
    if value["memory_reserve_bytes"] != MEMORY_RESERVE_BYTES:
        raise ProtocolError("resource memory reserve was modified")
    if value["estimated_duration_seconds"] is not None:
        _protocol_nonnegative_integer(value["estimated_duration_seconds"], "estimated duration")
        raise ProtocolError("protocol-v1 duration estimate must remain unknown")
    if value["time_budget_seconds"] != recipe["time_budget_seconds"]:
        raise ProtocolError("resource time budget does not match the recipe")

    observed_disk = _protocol_nonnegative_integer(
        value["observed_free_disk_bytes"], "observed free disk"
    )
    observed_memory = _protocol_nonnegative_integer(
        value["observed_unified_memory_bytes"], "observed unified memory", nullable=True
    )
    usable_memory = _protocol_nonnegative_integer(
        value["usable_unified_memory_bytes"], "usable unified memory", nullable=True
    )
    if observed_memory is None:
        if usable_memory is not None:
            raise ProtocolError("nullable unified-memory fields must be null together")
    elif usable_memory != max(0, observed_memory - MEMORY_RESERVE_BYTES):
        raise ProtocolError("usable unified memory does not match the frozen reserve")

    source = capabilities.get("source")
    inspected_source = source.get("disk_bytes") if isinstance(source, dict) else None
    expected_source = (
        inspected_source
        if isinstance(inspected_source, int)
        and not isinstance(inspected_source, bool)
        and inspected_source > 0
        else None
    )
    source_bytes = _protocol_nonnegative_integer(
        value["source_bytes"], "source bytes", nullable=True
    )
    output_bytes = _protocol_nonnegative_integer(
        value["estimated_output_bytes"], "estimated output bytes", nullable=True
    )
    temporary_bytes = _protocol_nonnegative_integer(
        value["estimated_temporary_bytes"], "estimated temporary bytes", nullable=True
    )
    required_disk = _protocol_nonnegative_integer(
        value["required_free_disk_bytes"], "required free disk", nullable=True
    )
    peak_memory = _protocol_nonnegative_integer(
        value["estimated_peak_memory_bytes"], "estimated peak memory", nullable=True
    )
    derived = (source_bytes, output_bytes, temporary_bytes, required_disk, peak_memory)
    if expected_source is None:
        if any(item is not None for item in derived):
            raise ProtocolError("unknown model size must null all size-derived resource values")
    else:
        if any(item is None for item in derived):
            raise ProtocolError("known model size requires every size-derived resource value")
        expected_output = sum(
            ((expected_source * (75 if mode == "mxfp8" else 45) + 99) // 100)
            + OUTPUT_OVERHEAD_BYTES
            for mode in recipe["quant_modes"]
        )
        expected_temporary = expected_source + TEMPORARY_OVERHEAD_BYTES
        expected_required_disk = expected_output + expected_temporary + DISK_RESERVE_BYTES
        expected_peak_memory = expected_source + PEAK_MEMORY_OVERHEAD_BYTES
        if derived != (
            expected_source,
            expected_output,
            expected_temporary,
            expected_required_disk,
            expected_peak_memory,
        ):
            raise ProtocolError("size-derived resource estimate values were modified")

    reason_codes = value["reason_codes"]
    if (
        not isinstance(reason_codes, list)
        or not all(isinstance(item, str) for item in reason_codes)
        or reason_codes != sorted(set(reason_codes))
        or not set(reason_codes) <= RESOURCE_REASON_CODES
    ):
        raise ProtocolError("resource estimate reason codes are invalid")
    expected_reasons = {"duration-estimate-unknown"}
    if "active-workloads-present" in reason_codes:
        expected_reasons.add("active-workloads-present")
    if observed_memory is None:
        expected_reasons.add("memory-observation-unknown")
    if expected_source is None:
        expected_reasons.add("resource-model-size-unknown")
    else:
        assert required_disk is not None and peak_memory is not None
        if required_disk > observed_disk:
            expected_reasons.add("resource-disk-insufficient")
        if usable_memory is not None and peak_memory > usable_memory:
            expected_reasons.add("resource-memory-insufficient")
    if set(reason_codes) != expected_reasons:
        raise ProtocolError("resource estimate reasons do not match its values")
    expected_feasibility = (
        "blocked"
        if expected_reasons & RESOURCE_BLOCKER_CODES
        else "review-required"
        if expected_reasons
        else "feasible"
    )
    if value["feasibility"] != expected_feasibility:
        raise ProtocolError("resource estimate feasibility does not match its reasons")
    return value


def validate_plan(plan: dict[str, Any]) -> tuple[Path, list[dict[str, Any]]]:
    base_plan_fields = {
        "schema_version",
        "run_id",
        "created_at",
        "workspace",
        "run_directory",
        "exact_parent",
        "capabilities",
        "recipe",
        "blockers",
        "steps",
    }
    if plan.get("schema_version") != SCHEMA_VERSION:
        raise ProtocolError("plan schema_version is not supported")
    run_id = plan.get("run_id")
    workspace_text = plan.get("workspace")
    run_directory_text = plan.get("run_directory")
    if not isinstance(run_id, str) or not isinstance(workspace_text, str) or not isinstance(run_directory_text, str):
        raise ProtocolError("plan identity fields are invalid")
    try:
        validate_run_id(run_id)
    except WorkflowInputError as exc:
        raise ProtocolError(str(exc)) from exc
    workspace = Path(workspace_text).expanduser().resolve()
    run_dir = Path(run_directory_text).expanduser().resolve()
    if run_dir != workspace / run_id:
        raise ProtocolError("run directory does not match workspace and run id")
    blockers = plan.get("blockers")
    steps = plan.get("steps")
    if not isinstance(blockers, list) or not isinstance(steps, list):
        raise ProtocolError("plan blockers and steps must be arrays")
    blocker_codes: list[str] = []
    for blocker in blockers:
        if (
            not isinstance(blocker, dict)
            or set(blocker) != {"code", "message"}
            or not isinstance(blocker["code"], str)
            or not blocker["code"]
            or not isinstance(blocker["message"], str)
            or not blocker["message"]
        ):
            raise ProtocolError("plan blocker shape is invalid")
        blocker_codes.append(blocker["code"])
    if len(blocker_codes) != len(set(blocker_codes)):
        raise ProtocolError("plan blocker codes must be unique")
    recipe = plan.get("recipe")
    if not isinstance(recipe, dict):
        raise ProtocolError("plan recipe must be an object")
    fixture_scenario = recipe.get("fixture_scenario")
    if fixture_scenario is not None:
        if set(plan) != base_plan_fields:
            raise ProtocolError("fixture plan shape is invalid")
        if set(recipe) != {"fixture_scenario"}:
            raise ProtocolError("fixture recipe contains unrelated operations")
        if fixture_scenario == "block":
            if blocker_codes != ["fixture-blocked"] or steps:
                raise ProtocolError("blocked fixture plan shape is invalid")
        elif len(steps) != 1 or blockers:
            raise ProtocolError("executable fixture plan shape is invalid")
    else:
        if set(plan) != base_plan_fields | {"resource_estimate"}:
            raise ProtocolError("real plan shape is invalid")
        exact_parent = plan.get("exact_parent")
        if not isinstance(exact_parent, str) or not Path(exact_parent).is_absolute():
            raise ProtocolError("real plan exact_parent is invalid")
        try:
            validate_real_recipe(recipe, Path(exact_parent))
        except WorkflowInputError as exc:
            raise ProtocolError(f"real plan recipe is invalid: {exc}") from exc
        if recipe["exact_parent"] != exact_parent:
            raise ProtocolError("plan and recipe exact_parent values differ")
        capabilities = plan.get("capabilities")
        if not isinstance(capabilities, dict) or capabilities.get("model") != exact_parent:
            raise ProtocolError("plan capabilities do not match exact_parent")
        resource_estimate = _validate_resource_estimate(
            plan.get("resource_estimate"), capabilities, recipe
        )
        if not set(blocker_codes) <= REAL_BLOCKER_CODES:
            raise ProtocolError("real plan contains an unsupported blocker code")
        expected_resource_blockers = set(resource_estimate["reason_codes"]) & RESOURCE_BLOCKER_CODES
        if set(blocker_codes) & RESOURCE_BLOCKER_CODES != expected_resource_blockers:
            raise ProtocolError("plan resource blockers do not match the estimate")
        unsupported_control = not recipe_control_is_supported(recipe)
        if ("recipe-control-unsupported" in blocker_codes) != unsupported_control:
            raise ProtocolError("plan recipe-control blocker does not match the recipe")
        source = capabilities.get("source")
        routing = capabilities.get("routing")
        conversion = routing.get("conversion") if isinstance(routing, dict) else None
        unsupported_source = (
            not isinstance(source, dict)
            or source.get("state") != "float-candidate"
            or not isinstance(conversion, dict)
            or conversion.get("allowed") is not True
        )
        if ("source-state-unsupported" in blocker_codes) != unsupported_source:
            raise ProtocolError("plan source-state blocker does not match capabilities")
        quant_modes = recipe.get("quant_modes")
        if blockers and steps:
            raise ProtocolError("blocked real plans must not contain executable steps")
        if not blockers and len(steps) != len(quant_modes):
            raise ProtocolError("quantization step count does not match the recipe")
    validated_conversion_modes: list[str] = []
    for step in steps:
        if not isinstance(step, dict):
            raise ProtocolError("plan step must be an object")
        allowed_step_fields = {
            "id",
            "kind",
            "display_name",
            "executable",
            "arguments",
            "working_directory",
            "environment_keys",
            "resumability",
        }
        if set(step) != allowed_step_fields:
            raise ProtocolError("plan step shape is invalid")
        if step.get("kind") not in {"workflow-fixture", "mlx-lm-convert"}:
            raise ProtocolError(f"step kind is not allowlisted: {step.get('kind')!r}")
        executable = step.get("executable")
        arguments = _require_string_list(step.get("arguments"), "step arguments")
        environment_keys = _require_string_list(step.get("environment_keys"), "environment keys")
        if not isinstance(executable, str):
            raise ProtocolError("step executable must be a string")
        code_root = Path(__file__).resolve().parents[1]
        if step["kind"] == "workflow-fixture":
            if Path(executable).resolve() != Path(sys.executable).resolve():
                raise ProtocolError("fixture executable does not match the allowlisted Python")
            helper = code_root / "tests" / "helpers" / "workflow_fake_stage.py"
            expected_prefix = [str(helper.resolve()), "--scenario"]
            if arguments[:2] != expected_prefix or len(arguments) != 5:
                raise ProtocolError("fixture arguments do not match the allowlisted shape")
            if arguments[2] not in {
                "success", "warning", "failure", "stderr-flood", "cancel", "interrupt-once"
            }:
                raise ProtocolError("fixture scenario is not allowlisted")
            if arguments[3:5] != ["--run-dir", str(run_dir)]:
                raise ProtocolError("fixture run directory argument is invalid")
            expected_resumability = "safe" if arguments[2] in {"cancel", "interrupt-once"} else "unsafe"
            if (
                step.get("id") != "fixture"
                or step.get("display_name") != f"Deterministic {arguments[2]} fixture"
                or step.get("resumability") != expected_resumability
            ):
                raise ProtocolError("fixture stage identity or resumability was modified")
        else:
            expected_executable = code_root / ".venv" / "bin" / "python"
            if Path(executable).resolve() != expected_executable.resolve():
                raise ProtocolError("conversion executable is not allowlisted")
            if (
                len(arguments) != 14
                or arguments[:4] != ["-m", "mlx_lm", "convert", "--hf-path"]
                or arguments[5] != "--mlx-path"
            ):
                raise ProtocolError("conversion arguments do not match the allowlisted shape")
            parent = plan.get("exact_parent")
            if not isinstance(parent, str) or arguments[4] != parent:
                raise ProtocolError("conversion parent does not match exact_parent")
            mode = arguments[9] if arguments[7:9] == ["--quantize", "--q-mode"] else None
            if mode not in {"mxfp4", "mxfp8", "affine"}:
                raise ProtocolError("conversion quantization mode is not allowlisted")
            validated_conversion_modes.append(mode)
            expected_group = "64" if mode == "affine" else "32"
            expected_bits = "8" if mode == "mxfp8" else "4"
            if arguments[10:] != [
                "--q-group-size", expected_group, "--q-bits", expected_bits
            ]:
                raise ProtocolError("conversion precision arguments are invalid")
            output = Path(arguments[6]).resolve()
            if output != run_dir / "artifacts" / f"model-{mode}":
                raise ProtocolError("conversion output is outside the run artifact directory")
            if (
                step.get("id") != f"quantize-{mode}"
                or step.get("display_name") != f"Quantize {mode}"
                or step.get("resumability") != "unsafe"
            ):
                raise ProtocolError("conversion stage identity or resumability was modified")
        if not set(environment_keys) <= ALLOWED_ENVIRONMENT_KEYS:
            raise ProtocolError("step requests non-allowlisted environment keys")
        working_directory = step.get("working_directory")
        expected_working_directory = workspace if step["kind"] == "workflow-fixture" else Path(__file__).resolve().parents[1]
        if not isinstance(working_directory, str) or Path(working_directory).resolve() != expected_working_directory:
            raise ProtocolError("step working directory does not match its allowlisted tool")
    if fixture_scenario is None and not blockers:
        if validated_conversion_modes != recipe["quant_modes"]:
            raise ProtocolError("conversion step order does not match recipe quant_modes")
    return run_dir, steps


def _manifest(plan: dict[str, Any]) -> dict[str, Any]:
    now = timestamp()
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": plan["run_id"],
        "state": "created",
        "resumability": "not-applicable",
        "exact_parent": plan.get("exact_parent"),
        "created_at": now,
        "updated_at": now,
        "last_committed_sequence": 0,
        "blockers": plan["blockers"],
        "terminal_reason": None,
        "last_completed_stage": None,
        "child_processes": [],
        "qualified": False,
        "cancellation": None,
    }


def _prepare_run_directory(run_dir: Path, plan: dict[str, Any], manifest: dict[str, Any]) -> None:
    if run_dir.exists():
        raise WorkflowInputError(f"run directory already exists: {run_dir}")
    parent = plan.get("exact_parent")
    if isinstance(parent, str):
        parent_path = Path(parent).expanduser().resolve()
        try:
            run_dir.relative_to(parent_path)
        except ValueError:
            pass
        else:
            raise WorkflowInputError("run directory must not be inside the parent artifact")
    for relative in ("inputs", "logs", "artifacts", "evaluations"):
        (run_dir / relative).mkdir(parents=True, exist_ok=False)
    atomic_write_json(run_dir / "run.json", manifest)
    atomic_write_json(run_dir / "plan.json", plan)
    atomic_write_json(run_dir / "recipe.json", plan["recipe"])
    capabilities = plan.get("capabilities")
    atomic_write_json(run_dir / "capabilities.json", capabilities if isinstance(capabilities, dict) else {})
    atomic_write_json(run_dir / "host.json", snapshot_host(Path(plan["workspace"])))
    versions: dict[str, Any] = {"python": sys.version.split()[0], "protocol_schema": SCHEMA_VERSION}
    for distribution in ("mlx", "mlx-lm", "transformers", "safetensors", "huggingface-hub"):
        try:
            versions[distribution] = importlib.metadata.version(distribution)
        except importlib.metadata.PackageNotFoundError:
            versions[distribution] = None
    atomic_write_json(
        run_dir / "versions.json",
        versions,
    )
    atomic_write_json(run_dir / "gates.json", {"required": [], "gates": []})
    atomic_write_json(run_dir / "rollback.json", {"exact_parent": plan.get("exact_parent")})
    if isinstance(parent, str) and isinstance(plan.get("recipe"), dict):
        if plan["recipe"].get("schema_version") == 1:
            atomic_write_json(
                run_dir / "inputs" / "parent-snapshot.json",
                snapshot_artifact(Path(parent)),
            )


def _command_record(step: dict[str, Any]) -> dict[str, Any]:
    executable = Path(step["executable"])
    arguments = list(step["arguments"])
    display = shlex.join(
        [redact_argument(str(executable)), *(redact_argument(value) for value in arguments)]
    )
    return {
        "stage": step["id"],
        "kind": step["kind"],
        "executable": str(executable),
        "executable_sha256": sha256(executable),
        "arguments": arguments,
        "working_directory": step["working_directory"],
        "environment_keys": step["environment_keys"],
        "redacted_display": display,
    }


def _drain(pipe: TextIO, stream_name: str, messages: queue.Queue[tuple[str, str] | None]) -> None:
    try:
        for line in iter(pipe.readline, ""):
            messages.put((stream_name, line.rstrip("\r\n")))
    finally:
        pipe.close()
        messages.put(None)


def _set_state(
    writer: JournalWriter,
    state: str,
    *, resumability: str | None = None,
    terminal_reason: str | None = None,
) -> None:
    writer.manifest["state"] = state
    if resumability is not None:
        writer.manifest["resumability"] = resumability
    writer.manifest["terminal_reason"] = terminal_reason


def _execute_step(writer: JournalWriter, step: dict[str, Any]) -> tuple[str, int]:
    stage = step["id"]
    stdout_path = writer.run_dir / "logs" / f"{stage}.stdout.log"
    stderr_path = writer.run_dir / "logs" / f"{stage}.stderr.log"
    environment = {
        key: os.environ[key]
        for key in step["environment_keys"]
        if key in os.environ and not SECRET_KEY.search(key)
    }
    interrupted = False
    previous_handler = signal.getsignal(signal.SIGINT)

    def interrupt(_signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGINT, interrupt)
    try:
        process = subprocess.Popen(
            [step["executable"], *step["arguments"]],
            cwd=step["working_directory"],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError as exc:
        signal.signal(signal.SIGINT, previous_handler)
        safe, _ = redact_text(f"cannot launch allowlisted stage: {exc}")
        stdout_path.touch()
        stderr_path.write_text(safe + "\n", encoding="utf-8")
        writer.emit("stage.started", stage, {"display_name": step["display_name"], "pid": None})
        writer.emit("stage.log", stage, {"stream": "stderr", "message": safe})
        return "failed", 127
    writer.manifest["child_processes"].append(
        {"pid": process.pid, "stage": stage, "launched_at": timestamp(), "signal": None}
    )
    writer.emit(
        "stage.started",
        stage,
        {"display_name": step["display_name"], "pid": process.pid},
    )
    writer.emit("stage.progress", stage, {"completed": 0, "total": 1, "unit": "steps"})
    assert process.stdout is not None and process.stderr is not None
    messages: queue.Queue[tuple[str, str] | None] = queue.Queue(maxsize=1024)
    threads = [
        threading.Thread(target=_drain, args=(process.stdout, "stdout", messages), daemon=True),
        threading.Thread(target=_drain, args=(process.stderr, "stderr", messages), daemon=True),
    ]
    for thread in threads:
        thread.start()
    streams_done = 0
    cancelled = False
    cancellation_sent = False
    cancellation_deadline: float | None = None
    try:
        with stdout_path.open("a", encoding="utf-8") as stdout_log, stderr_path.open(
            "a", encoding="utf-8"
        ) as stderr_log:
            while streams_done < 2 or process.poll() is None:
                if (
                    (writer.run_dir / "cancel.request.json").exists()
                    and process.poll() is None
                    and not cancellation_sent
                ):
                    cancelled = True
                    process.terminate()
                    writer.manifest["child_processes"][-1]["signal"] = "SIGTERM"
                    cancellation_sent = True
                    cancellation_deadline = time.monotonic() + CANCELLATION_GRACE_SECONDS
                if (
                    cancellation_deadline is not None
                    and time.monotonic() >= cancellation_deadline
                    and process.poll() is None
                ):
                    process.kill()
                    writer.manifest["child_processes"][-1]["signal"] = "SIGKILL"
                    cancellation_deadline = None
                if interrupted and process.poll() is None:
                    process.terminate()
                    writer.manifest["child_processes"][-1]["signal"] = "SIGTERM"
                try:
                    message = messages.get(timeout=0.05)
                except queue.Empty:
                    continue
                if message is None:
                    streams_done += 1
                    continue
                stream_name, raw = message
                log = stdout_log if stream_name == "stdout" else stderr_log
                safe, was_redacted = redact_text(raw)
                log.write(safe + "\n")
                log.flush()
                payload: dict[str, Any] = {"stream": stream_name, "message": safe}
                if was_redacted:
                    payload["redacted"] = True
                writer.emit("stage.log", stage, payload)
            return_code = process.wait(timeout=2)
    finally:
        signal.signal(signal.SIGINT, previous_handler)
    writer.manifest["child_processes"][-1]["exit_code"] = return_code
    writer.manifest["child_processes"][-1]["ended_at"] = timestamp()
    if cancelled:
        return "cancelled", return_code
    if interrupted:
        return "interrupted", return_code
    if return_code != 0:
        return "failed", return_code
    writer.emit("stage.progress", stage, {"completed": 1, "total": 1, "unit": "steps"})
    writer.manifest["last_completed_stage"] = stage
    writer.emit("stage.completed", stage, {"exit_code": 0})
    if step["kind"] == "workflow-fixture":
        artifact = writer.run_dir / "artifacts" / "candidate"
    else:
        artifact = Path(step["arguments"][3])
    if artifact.exists():
        relative_artifact = artifact.relative_to(writer.run_dir)
        writer.emit(
            "artifact.discovered",
            stage,
            {"relative_path": str(relative_artifact), "kind": "candidate", "complete": True},
        )
    if step["kind"] == "workflow-fixture" and artifact.exists():
        evaluation = {
            "name": "fixture",
            "parent": writer.manifest.get("exact_parent"),
            "score": 1,
            "status": "passed",
        }
        atomic_write_json(writer.run_dir / "evaluations" / "fixture.json", evaluation)
        atomic_write_json(
            writer.run_dir / "gates.json",
            {
                "required": ["structural"],
                "gates": [
                    {
                        "gate": "structural",
                        "status": "passed",
                        "evidence": "evaluations/fixture.json",
                    }
                ],
            },
        )
    return "completed", 0


def _finalize_cancelled_run(writer: JournalWriter, step: dict[str, Any]) -> int:
    try:
        marker = json.loads((writer.run_dir / "cancel.request.json").read_text(encoding="utf-8"))
        if not isinstance(marker, dict):
            raise ValueError("marker is not an object")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        marker = {
            "requested_at": timestamp(),
            "marker_error": f"invalid cancellation marker: {type(exc).__name__}",
        }
    requested_at = marker.get("requested_at")
    if not isinstance(requested_at, str) or not requested_at:
        marker = {
            **marker,
            "requested_at": timestamp(),
            "marker_error": "invalid cancellation marker: missing requested_at",
        }
    child = writer.manifest["child_processes"][-1]
    writer.manifest["cancellation"] = {
        **marker,
        "affected_pids": [child["pid"]],
        "signal": child["signal"],
    }
    partial_outputs = sorted(
        str(path.relative_to(writer.run_dir))
        for path in (writer.run_dir / "artifacts").iterdir()
    )
    _set_state(
        writer,
        "cancelled",
        resumability=step["resumability"],
        terminal_reason="cancel-requested",
    )
    writer.emit(
        "run.cancelled",
        None,
        {
            "state": "cancelled",
            "signal": writer.manifest["cancellation"]["signal"],
            "affected_pids": writer.manifest["cancellation"]["affected_pids"],
            "requested_at": writer.manifest["cancellation"]["requested_at"],
            "last_completed_stage": writer.manifest["last_completed_stage"],
            "partial_outputs": partial_outputs,
            "resumability": step["resumability"],
        },
    )
    return 6


def run_plan(plan: dict[str, Any], stream: TextIO, *, dry_run: bool = False) -> int:
    run_dir, steps = validate_plan(plan)
    if dry_run:
        writer = MachineWriter(plan["run_id"], stream)
        writer.emit("run.created", None, {"state": "created", "dry_run": True})
        writer.emit(
            "plan.blocked" if plan["blockers"] else "plan.ready",
            "plan",
            {"step_count": len(steps), "blockers": plan["blockers"], "dry_run": True},
        )
        if plan["blockers"]:
            return 3
        writer.emit(
            "run.completed",
            None,
            {"state": "completed", "resumability": "not-applicable", "dry_run": True},
        )
        return 0
    manifest = _manifest(plan)
    _prepare_run_directory(run_dir, plan, manifest)
    atomic_write_json(
        run_dir / "commands.json",
        {"schema_version": SCHEMA_VERSION, "commands": [_command_record(step) for step in steps]},
    )
    writer = JournalWriter(run_dir, manifest, stream)
    try:
        writer.emit(
            "run.created",
            None,
            {"state": "created", "resumability": "not-applicable"},
        )
        if plan["blockers"]:
            _set_state(writer, "blocked")
            writer.emit(
                "plan.blocked",
                "plan",
                {
                    "state": "blocked",
                    "resumability": "not-applicable",
                    "blockers": plan["blockers"],
                },
            )
            return 3
        _set_state(writer, "planned", resumability="not-applicable")
        writer.emit("run.state", None, {"state": "planned", "resumability": "not-applicable"})
        writer.emit("plan.ready", "plan", {"step_count": len(steps)})
        _set_state(writer, "running", resumability="unsafe")
        writer.emit("run.state", None, {"state": "running", "resumability": "unsafe"})
        for step in steps:
            if step["kind"] == "workflow-fixture" and step["arguments"][2] == "warning":
                writer.emit(
                    "warning.raised",
                    step["id"],
                    {"code": "fixture-warning", "message": "Deterministic fixture warning."},
                )
            outcome, return_code = _execute_step(writer, step)
            if outcome == "failed":
                writer.emit(
                    "stage.failed",
                    step["id"],
                    {
                        "exit_code": return_code,
                        "code": "stage-exit-nonzero",
                        "message": "Allowlisted stage exited nonzero.",
                        "resumability": step["resumability"],
                    },
                )
                _set_state(writer, "failed", resumability=step["resumability"], terminal_reason="stage-exit-nonzero")
                writer.emit(
                    "run.state",
                    None,
                    {
                        "state": "failed",
                        "resumability": step["resumability"],
                        "terminal_reason": "stage-exit-nonzero",
                    },
                )
                return 5
            if outcome == "cancelled":
                return _finalize_cancelled_run(writer, step)
            if outcome == "interrupted":
                _set_state(
                    writer,
                    "interrupted",
                    resumability=step["resumability"],
                    terminal_reason="runner-interrupted",
                )
                writer.emit(
                    "run.interrupted",
                    None,
                    {"state": "interrupted", "resumability": step["resumability"]},
                )
                return 6
        _set_state(writer, "completed", resumability="not-applicable")
        writer.emit(
            "run.completed",
            None,
            {"state": "completed", "resumability": "not-applicable", "qualified": False},
        )
        return 0
    finally:
        writer.close()


def resume_run(run_dir: Path, stream: TextIO) -> int:
    run_dir = run_dir.expanduser().resolve()
    try:
        manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
        plan = json.loads((run_dir / "plan.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"cannot load resumable run: {exc}") from exc
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("run_id") != plan.get("run_id"):
        raise ProtocolError("run manifest and plan identities do not match protocol v1")
    events, corrupt_tail = load_journal(run_dir / "events.jsonl", manifest["run_id"])
    if corrupt_tail:
        raise ProtocolError("cannot append after a recoverable corrupt journal tail")
    if manifest.get("last_committed_sequence") != len(events):
        manifest["last_committed_sequence"] = len(events)
        manifest["updated_at"] = timestamp()
        atomic_write_json(run_dir / "run.json", manifest)
    if manifest.get("state") != "interrupted" or manifest.get("resumability") != "safe":
        raise WorkflowInputError("run is not journal-declared safe to resume")
    validated_run_dir, steps = validate_plan(plan)
    if validated_run_dir != run_dir:
        raise ProtocolError("persisted plan resolves to a different run directory")
    last_completed = manifest.get("last_completed_stage")
    if last_completed is not None:
        completed_ids = [step["id"] for step in steps]
        try:
            steps = steps[completed_ids.index(last_completed) + 1 :]
        except ValueError as exc:
            raise ProtocolError("last completed stage is absent from the persisted plan") from exc
    writer = JournalWriter(run_dir, manifest, stream)
    try:
        _set_state(writer, "running", resumability="unsafe", terminal_reason=None)
        writer.emit(
            "run.state",
            None,
            {"state": "running", "resumability": "unsafe", "resumed": True},
        )
        for step in steps:
            outcome, return_code = _execute_step(writer, step)
            if outcome != "completed":
                if outcome == "failed":
                    writer.emit(
                        "stage.failed",
                        step["id"],
                        {"exit_code": return_code, "code": "stage-exit-nonzero", "resumability": step["resumability"]},
                    )
                    _set_state(writer, "failed", resumability=step["resumability"], terminal_reason="stage-exit-nonzero")
                    writer.emit(
                        "run.state",
                        None,
                        {
                            "state": "failed",
                            "resumability": step["resumability"],
                            "terminal_reason": "stage-exit-nonzero",
                        },
                    )
                    return 5
                if outcome == "cancelled":
                    return _finalize_cancelled_run(writer, step)
                _set_state(writer, "interrupted", resumability=step["resumability"], terminal_reason="resume-interrupted")
                writer.emit("run.interrupted", None, {"state": "interrupted", "resumability": step["resumability"]})
                return 6
        _set_state(writer, "completed", resumability="not-applicable", terminal_reason=None)
        writer.emit(
            "run.completed",
            None,
            {
                "state": "completed",
                "resumability": "not-applicable",
                "qualified": False,
                "resumed": True,
            },
        )
        return 0
    finally:
        writer.close()


def qualify_run(run_dir: Path, stream: TextIO) -> int:
    run_dir = run_dir.expanduser().resolve()
    try:
        manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
        plan = json.loads((run_dir / "plan.json").read_text(encoding="utf-8"))
        gates = json.loads((run_dir / "gates.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"cannot load qualification evidence: {exc}") from exc
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise ProtocolError("run manifest schema_version is not supported")
    recipe = plan.get("recipe")
    if (
        isinstance(recipe, dict)
        and recipe.get("schema_version") == 1
        and gates == {"required": [], "gates": []}
    ):
        from workflow_real_qualification import generate_real_qualification_evidence

        gates = generate_real_qualification_evidence(
            run_dir,
            plan=plan,
            manifest=manifest,
        )
    events, corrupt_tail = load_journal(run_dir / "events.jsonl", manifest["run_id"])
    if corrupt_tail:
        raise ProtocolError("qualification is disabled for a recoverable corrupt journal tail")
    manifest["last_committed_sequence"] = len(events)
    exact_parent = manifest.get("exact_parent")
    blockers: list[str] = []
    if manifest.get("state") != "completed":
        blockers.append("run-not-completed")
    if manifest.get("blockers"):
        blockers.append("active-plan-blockers")
    if (
        not isinstance(exact_parent, str)
        or plan.get("exact_parent") != exact_parent
        or not Path(exact_parent).exists()
    ):
        blockers.append("exact-parent-missing-or-changed")
    required = gates.get("required")
    gate_items = gates.get("gates")
    if not isinstance(required, list) or not required or not isinstance(gate_items, list):
        blockers.append("required-gates-missing")
        required = []
        gate_items = []
    statuses = {
        item.get("gate"): item.get("status")
        for item in gate_items
        if isinstance(item, dict) and isinstance(item.get("gate"), str)
    }
    if any(statuses.get(name) != "passed" for name in required):
        blockers.append("required-gate-not-passed")
    if isinstance(recipe, dict) and recipe.get("schema_version") == 1:
        expected_required = recipe.get("validation", {}).get("required_gates")
        if required != expected_required:
            blockers.append("required-gates-do-not-match-recipe")
        for item in gate_items:
            if not isinstance(item, dict):
                blockers.append("gate-record-invalid")
                continue
            evidence = item.get("evidence")
            expected_sha256 = item.get("sha256")
            if not isinstance(evidence, str) or not isinstance(expected_sha256, str):
                blockers.append("gate-evidence-invalid")
                continue
            relative = Path(evidence)
            resolved = (run_dir / relative).resolve()
            try:
                resolved.relative_to(run_dir)
            except ValueError:
                blockers.append("gate-evidence-outside-run")
                continue
            if relative.is_absolute() or ".." in relative.parts or not resolved.is_file():
                blockers.append("gate-evidence-invalid")
            elif sha256(resolved) != expected_sha256:
                blockers.append("gate-evidence-hash-mismatch")
    writer = JournalWriter(run_dir, manifest, stream)
    try:
        if blockers:
            writer.manifest["qualified"] = False
            for name in required:
                writer.emit(
                    "promotion.gate",
                    "qualify",
                    {"gate": name, "status": statuses.get(name, "pending")},
                )
            writer.emit(
                "warning.raised",
                "qualify",
                {"code": "qualification-blocked", "blockers": blockers},
            )
            return 3
        evaluation_path = run_dir / "evaluations" / "fixture.json"
        if evaluation_path.is_file():
            evaluation = json.loads(evaluation_path.read_text(encoding="utf-8"))
            writer.emit(
                "metric.recorded",
                "qualify",
                {
                    "name": "fixture_score",
                    "value": evaluation.get("score"),
                    "unit": "ratio",
                    "source": "evaluations/fixture.json",
                },
            )
            writer.emit(
                "evaluation.recorded",
                "qualify",
                {"relative_path": "evaluations/fixture.json", "parent": exact_parent},
            )
        writer.manifest["qualified"] = True
        for item in gate_items:
            writer.emit("promotion.gate", "qualify", item)
        return 0
    finally:
        writer.close()
