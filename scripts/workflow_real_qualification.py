"""Parent-relative qualification for completed real uniform MLX-LM runs."""

from __future__ import annotations

import importlib.metadata
import json
from pathlib import Path
from typing import Any

from inspect_mlx_model import inspect_model
from workflow_promotion import snapshot_artifact
from workflow_protocol import ProtocolError, atomic_write_json


FROZEN_PROMPTS = [
    "user: hello\nassistant:",
    "user: one two three\nassistant:",
]


def _sha256(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_and_generate(path: Path) -> dict[str, Any]:
    from mlx_lm import generate, load
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(str(path))
    sampler = make_sampler(temp=0.0)
    outputs = [
        generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=4,
            sampler=sampler,
            verbose=False,
        )
        for prompt in FROZEN_PROMPTS
    ]
    repeated = [
        generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=4,
            sampler=sampler,
            verbose=False,
        )
        for prompt in FROZEN_PROMPTS
    ]
    return {
        "load_passed": True,
        "outputs": [
            {"case": f"prompt-{index + 1}", "prompt": prompt, "output": output}
            for index, (prompt, output) in enumerate(zip(FROZEN_PROMPTS, outputs, strict=True))
        ],
        "repeat_deterministic": repeated == outputs,
    }


def generate_real_qualification_evidence(
    run_dir: Path,
    *,
    plan: dict[str, Any],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    run_dir = run_dir.expanduser().resolve()
    recipe = plan.get("recipe")
    if not isinstance(recipe, dict) or recipe.get("schema_version") != 1:
        raise ProtocolError("real qualification requires a canonical real recipe")
    modes = recipe.get("quant_modes")
    if not isinstance(modes, list) or len(modes) != 1 or not isinstance(modes[0], str):
        raise ProtocolError("beta qualification requires exactly one uniform candidate")
    mode = modes[0]
    parent_value = plan.get("exact_parent")
    if not isinstance(parent_value, str):
        raise ProtocolError("real qualification exact parent is missing")
    parent = Path(parent_value).resolve()
    candidate = run_dir / "artifacts" / f"model-{mode}"
    parent_snapshot_path = run_dir / "inputs" / "parent-snapshot.json"
    try:
        parent_before = json.loads(parent_snapshot_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"pre-run parent snapshot is missing or invalid: {exc}") from exc
    parent_after = snapshot_artifact(parent)
    candidate_snapshot = snapshot_artifact(candidate)
    parent_unchanged = parent_after == parent_before

    config_path = candidate / "config.json"
    try:
        candidate_config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"candidate config is missing or invalid: {exc}") from exc
    quantization = candidate_config.get("quantization")
    expected_bits = 8 if mode == "mxfp8" else 4
    expected_group = 64 if mode == "affine" else 32
    quantization_matches = quantization == {
        "group_size": expected_group,
        "bits": expected_bits,
        "mode": mode,
    }
    capability = inspect_model(candidate)
    structure_passed = (
        capability.get("status") == "pass"
        and capability.get("source", {}).get("state") == "quantized"
        and quantization_matches
    )

    parent_runtime = _load_and_generate(parent)
    candidate_runtime = _load_and_generate(candidate)
    runtime_passed = (
        parent_runtime["load_passed"]
        and candidate_runtime["load_passed"]
        and parent_runtime["repeat_deterministic"]
        and candidate_runtime["repeat_deterministic"]
    )
    evaluations = run_dir / "evaluations"
    provenance_path = evaluations / "provenance-structure.json"
    runtime_path = evaluations / "deterministic-language-schema.json"
    parity_path = evaluations / "parent-parity.json"
    atomic_write_json(
        provenance_path,
        {
            "schema_version": 1,
            "status": "passed" if structure_passed else "failed",
            "exact_parent": str(parent),
            "candidate": str(candidate),
            "expected_quantization": {
                "mode": mode,
                "group_size": expected_group,
                "bits": expected_bits,
            },
            "candidate_quantization": quantization,
            "candidate_capability": capability,
            "candidate_snapshot": candidate_snapshot,
        },
    )
    atomic_write_json(
        runtime_path,
        {
            "schema_version": 1,
            "status": "passed" if runtime_passed else "failed",
            "contract": {
                "mlx_lm": importlib.metadata.version("mlx-lm"),
                "transformers": importlib.metadata.version("transformers"),
                "seed": 0,
                "sampler": "greedy-temperature-zero",
                "max_tokens": 4,
                "prompts": FROZEN_PROMPTS,
                "claim": "deterministic load/generation smoke only; no quality claim",
            },
            "parent": parent_runtime,
            "candidate": candidate_runtime,
        },
    )
    atomic_write_json(
        parity_path,
        {
            "schema_version": 1,
            "status": "passed" if parent_unchanged else "failed",
            "before": parent_before,
            "after": parent_after,
            "unchanged": parent_unchanged,
        },
    )
    required = recipe.get("validation", {}).get("required_gates")
    expected_required = [
        "provenance-structure",
        "deterministic-language-schema",
        "parent-parity",
    ]
    if required != expected_required:
        raise ProtocolError("real qualification required gates do not match protocol v1")
    statuses = {
        "provenance-structure": structure_passed,
        "deterministic-language-schema": runtime_passed,
        "parent-parity": parent_unchanged,
    }
    paths = {
        "provenance-structure": provenance_path,
        "deterministic-language-schema": runtime_path,
        "parent-parity": parity_path,
    }
    gates = {
        "required": expected_required,
        "gates": [
            {
                "gate": name,
                "status": "passed" if statuses[name] else "failed",
                "evidence": str(paths[name].relative_to(run_dir)),
                "sha256": _sha256(paths[name]),
            }
            for name in expected_required
        ],
    }
    atomic_write_json(run_dir / "gates.json", gates)
    return gates
