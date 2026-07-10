"""Protocol-v1 serialization and persistence primitives."""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TextIO


SCHEMA_VERSION = 1
RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class WorkflowInputError(ValueError):
    """Input is invalid or outside the v1 contract."""


class ProtocolError(RuntimeError):
    """Persisted protocol state is incompatible or corrupt."""


def timestamp() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _is_rfc3339_utc(value: Any) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return False
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.tzinfo == UTC


def validate_run_id(value: str) -> str:
    if not RUN_ID_PATTERN.fullmatch(value):
        raise WorkflowInputError("run id must contain only letters, numbers, '.', '_' or '-'")
    return value


def read_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WorkflowInputError(f"cannot read JSON object {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise WorkflowInputError(f"expected a JSON object: {path}")
    return value


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def load_journal(path: Path, run_id: str) -> tuple[list[dict[str, Any]], bool]:
    """Validate a v1 journal, tolerating only one malformed final fragment."""
    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProtocolError(f"cannot read event journal: {exc}") from exc
    events: list[dict[str, Any]] = []
    corrupt_tail = False
    for index, line in enumerate(raw_lines):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            if index == len(raw_lines) - 1:
                corrupt_tail = True
                break
            raise ProtocolError(f"malformed journal line {index + 1}: {exc}") from exc
        if not isinstance(event, dict):
            raise ProtocolError(f"journal line {index + 1} is not an object")
        required = {"schema_version", "run_id", "sequence", "timestamp", "type", "stage", "payload"}
        if not required <= set(event):
            raise ProtocolError(f"journal line {index + 1} is missing envelope fields")
        if (
            not isinstance(event["schema_version"], int)
            or isinstance(event["schema_version"], bool)
            or event["schema_version"] != SCHEMA_VERSION
        ):
            raise ProtocolError("journal schema_version is not supported")
        if not isinstance(event["run_id"], str) or event["run_id"] != run_id:
            raise ProtocolError("journal run id changed")
        if (
            not isinstance(event["sequence"], int)
            or isinstance(event["sequence"], bool)
            or event["sequence"] != len(events) + 1
        ):
            raise ProtocolError("journal sequence is not contiguous")
        if not _is_rfc3339_utc(event["timestamp"]):
            raise ProtocolError("journal timestamp must be RFC 3339 UTC")
        if not isinstance(event["type"], str) or not event["type"]:
            raise ProtocolError("journal event type must be a non-empty string")
        if event["stage"] is not None and not isinstance(event["stage"], str):
            raise ProtocolError("journal stage must be a string or null")
        if not isinstance(event["payload"], dict):
            raise ProtocolError("journal payload must be an object")
        events.append(event)
    return events, corrupt_tail


class MachineWriter:
    """Writes pure NDJSON envelopes to a stream."""

    def __init__(self, run_id: str, stream: TextIO, *, sequence: int = 0) -> None:
        self.run_id = validate_run_id(run_id)
        self.stream = stream
        self.sequence = sequence

    def emit(self, event_type: str, stage: str | None, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(event_type, str) or not event_type:
            raise ProtocolError("event type must be a non-empty string")
        if stage is not None and not isinstance(stage, str):
            raise ProtocolError("event stage must be a string or null")
        if not isinstance(payload, dict):
            raise ProtocolError("event payload must be an object")
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
        self.stream.write(json.dumps(event, separators=(",", ":")) + "\n")
        self.stream.flush()
        return event
