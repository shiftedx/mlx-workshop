"""Qualification and metadata-only immutable local staging primitives."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import statistics
from pathlib import Path
from typing import Any

from workflow_protocol import atomic_write_json, timestamp


STAGE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class PromotionError(RuntimeError):
    """Qualification or immutable staging prerequisites were not met."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_artifact(path: Path) -> dict[str, Any]:
    """Return a stable, content-addressed snapshot without following symlinks."""
    root = path.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"artifact is not a directory: {root}")
    entries: list[dict[str, Any]] = []
    for entry in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
        relative = entry.relative_to(root).as_posix()
        if entry.is_symlink():
            target = os.readlink(entry)
            entries.append(
                {
                    "path": relative,
                    "type": "symlink",
                    "target": target,
                    "sha256": hashlib.sha256(target.encode("utf-8")).hexdigest(),
                }
            )
        elif entry.is_file():
            entries.append(
                {
                    "path": relative,
                    "type": "file",
                    "size_bytes": entry.stat().st_size,
                    "sha256": _sha256(entry),
                }
            )
        elif entry.is_dir():
            entries.append({"path": relative, "type": "directory"})
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "path": str(root),
        "tree_sha256": hashlib.sha256(canonical).hexdigest(),
        "entries": entries,
    }


def _raw_evidence_record(root: Path, relative: str) -> dict[str, Any] | None:
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        return None
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        return None
    if not resolved.is_file():
        return None
    return {
        "path": candidate.as_posix(),
        "sha256": _sha256(resolved),
        "size_bytes": resolved.stat().st_size,
    }


def _samples(values: Any) -> tuple[list[str], list[float]] | None:
    if not isinstance(values, list) or len(values) < 3:
        return None
    cases: list[str] = []
    samples: list[float] = []
    for item in values:
        if not isinstance(item, dict):
            return None
        case = item.get("case")
        value = item.get("value")
        if not isinstance(case, str) or not case or not isinstance(value, (int, float)):
            return None
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            return None
        cases.append(case)
        samples.append(numeric)
    if len(set(cases)) != len(cases):
        return None
    return cases, samples


def _performance_result(value: Any) -> tuple[dict[str, Any] | None, list[str]]:
    blockers: list[str] = []
    if not isinstance(value, dict):
        return None, ["performance-evidence-missing"]
    parent = _samples(value.get("parent_samples"))
    candidate = _samples(value.get("candidate_samples"))
    if parent is None or candidate is None or parent[0] != candidate[0]:
        return None, ["performance-samples-invalid-or-unpaired"]
    minimum = value.get("minimum_improvement_fraction")
    maximum_cv = value.get("maximum_coefficient_of_variation")
    if not isinstance(minimum, (int, float)) or not 0 <= float(minimum) <= 1:
        blockers.append("performance-minimum-invalid")
    if not isinstance(maximum_cv, (int, float)) or not 0 <= float(maximum_cv) <= 1:
        blockers.append("performance-noise-limit-invalid")
    if blockers:
        return None, blockers

    parent_mean = statistics.fmean(parent[1])
    candidate_mean = statistics.fmean(candidate[1])
    parent_cv = statistics.pstdev(parent[1]) / parent_mean
    candidate_cv = statistics.pstdev(candidate[1]) / candidate_mean
    improvement = candidate_mean / parent_mean - 1
    if parent_cv > float(maximum_cv) or candidate_cv > float(maximum_cv):
        blockers.append("performance-claim-noisy")
    if improvement < float(minimum):
        blockers.append("performance-improvement-below-threshold")
    return {
        "metric": value.get("metric"),
        "cases": parent[0],
        "parent_mean": parent_mean,
        "candidate_mean": candidate_mean,
        "parent_coefficient_of_variation": parent_cv,
        "candidate_coefficient_of_variation": candidate_cv,
        "improvement_fraction": improvement,
        "minimum_improvement_fraction": float(minimum),
        "maximum_coefficient_of_variation": float(maximum_cv),
    }, blockers


def evaluate_qualification(
    evidence: dict[str, Any], *, evidence_root: Path
) -> dict[str, Any]:
    """Evaluate frozen parent-relative evidence without inferring absent gates."""
    root = evidence_root.expanduser().resolve()
    blockers: list[str] = []
    if evidence.get("schema_version") != 1:
        blockers.append("schema-version-unsupported")
    if not isinstance(evidence.get("exact_parent"), str) or not evidence["exact_parent"]:
        blockers.append("exact-parent-missing")
    if not isinstance(evidence.get("candidate"), str) or not evidence["candidate"]:
        blockers.append("candidate-identity-missing")
    frozen_contract = evidence.get("frozen_contract")
    if not isinstance(frozen_contract, dict) or not frozen_contract:
        blockers.append("frozen-contract-missing")

    required = evidence.get("required_gates")
    gate_items = evidence.get("gates")
    if not isinstance(required, list) or not required or not all(
        isinstance(name, str) and name for name in required
    ):
        blockers.append("required-gates-missing")
        required = []
    if not isinstance(gate_items, list):
        blockers.append("gate-evidence-missing")
        gate_items = []

    gates: dict[str, dict[str, Any]] = {}
    raw_records: dict[str, dict[str, Any]] = {}
    for item in gate_items:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            blockers.append("gate-record-invalid")
            continue
        name = item["name"]
        if name in gates:
            blockers.append(f"gate-duplicate:{name}")
            continue
        gates[name] = item

    for name in required:
        item = gates.get(name)
        if item is None:
            blockers.append(f"gate-missing:{name}")
            continue
        if item.get("status") != "passed":
            blockers.append(f"gate-not-passed:{name}")
        links = item.get("evidence")
        if not isinstance(links, list) or not links:
            blockers.append(f"gate-evidence-missing:{name}")
            continue
        for link in links:
            record = _raw_evidence_record(root, link) if isinstance(link, str) else None
            if record is None:
                blockers.append(f"gate-evidence-invalid:{name}")
            else:
                raw_records[record["path"]] = record

    performance: dict[str, Any] | None = None
    if "performance" in required:
        performance, performance_blockers = _performance_result(evidence.get("performance"))
        blockers.extend(performance_blockers)

    blockers = sorted(set(blockers))
    qualified = not blockers
    return {
        "schema_version": 1,
        "qualified": qualified,
        "classification": "qualified" if qualified else "experimental",
        "exact_parent": evidence.get("exact_parent"),
        "candidate": evidence.get("candidate"),
        "frozen_contract": frozen_contract,
        "required_gates": required,
        "gates": [gates[name] for name in required if name in gates],
        "raw_evidence": [raw_records[name] for name in sorted(raw_records)],
        "performance": performance,
        "blockers": blockers,
    }


def _inside(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
    except ValueError:
        return False
    return True


def stage_candidate(
    *,
    parent: Path,
    candidate: Path,
    staging_root: Path,
    stage_id: str,
    qualification: dict[str, Any],
) -> Path:
    """Finalize metadata in a new stage directory without copying or mutating artifacts."""
    if not STAGE_ID_PATTERN.fullmatch(stage_id):
        raise ValueError("stage_id must contain only letters, numbers, '.', '_' or '-'")
    parent = parent.expanduser().resolve()
    candidate = candidate.expanduser().resolve()
    staging_root = staging_root.expanduser().resolve()
    if not parent.is_dir() or not candidate.is_dir():
        raise ValueError("parent and candidate must be existing directories")
    if parent == candidate:
        raise PromotionError("candidate must be distinct from its exact parent")
    if not staging_root.is_dir():
        raise ValueError(f"staging root is not a directory: {staging_root}")
    if _inside(staging_root, parent) or _inside(staging_root, candidate):
        raise PromotionError("staging root cannot be inside the parent or candidate")

    stage = staging_root / stage_id
    if stage.exists():
        raise FileExistsError(f"staging directory already exists: {stage}")

    parent_before = snapshot_artifact(parent)
    candidate_before = snapshot_artifact(candidate)
    if qualification.get("exact_parent") != parent_before["tree_sha256"]:
        raise PromotionError("qualification exact parent does not match the source snapshot")
    if qualification.get("candidate") != candidate_before["tree_sha256"]:
        raise PromotionError("qualification candidate does not match the source snapshot")
    classification = qualification.get("classification")
    if classification not in {"qualified", "experimental"}:
        raise PromotionError("qualification classification is invalid")
    if classification == "qualified" and qualification.get("qualified") is not True:
        raise PromotionError("qualified staging requires an affirmative qualification result")

    stage.mkdir()
    hashes = {
        "schema_version": 1,
        "exact_parent": parent_before,
        "candidate": candidate_before,
        "raw_evidence": qualification.get("raw_evidence", []),
    }
    rollback = {
        "schema_version": 1,
        "exact_parent": str(parent),
        "exact_parent_tree_sha256": parent_before["tree_sha256"],
        "candidate": str(candidate),
        "parent_unchanged": True,
        "canonical_artifacts_untouched": True,
        "rollback_action": "discard-staging-directory",
        "staging_directory": str(stage),
    }
    atomic_write_json(stage / "hashes.json", hashes)
    atomic_write_json(stage / "rollback.json", rollback)

    parent_after = snapshot_artifact(parent)
    candidate_after = snapshot_artifact(candidate)
    if parent_after != parent_before or candidate_after != candidate_before:
        raise PromotionError("source artifact changed while staging metadata")

    manifest = {
        "schema_version": 1,
        "stage_id": stage_id,
        "finalized_at": timestamp(),
        "classification": classification,
        "qualified": qualification.get("qualified") is True,
        "artifact_mode": "reference-only",
        "exact_parent": str(parent),
        "candidate": str(candidate),
        "source_immutability_validated": True,
        "qualification": qualification,
        "limitations": qualification.get("blockers", []),
        "local_only": True,
        "lm_studio_untouched": True,
        "published": False,
        "deleted_sources": False,
    }
    atomic_write_json(stage / "staging-manifest.json", manifest)
    return stage
