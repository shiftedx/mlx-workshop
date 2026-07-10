"""Measured MLX layer sensitivity and exact mixed-precision materialization."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from workflow_sensitivity import (
    CalibrationContract, EvaluationObservation, ModuleIdentifier, ModuleSpec,
    PrecisionSpec, RuntimeAssignmentSupport, SearchPolicy, SensitivityRequest,
)


PRECISIONS = {
    "fp16": PrecisionSpec("fp16", "float", 16, None, 0, "dense-bits-v1"),
    "mxfp4": PrecisionSpec("mxfp4", "mxfp4", 4, 32, 1, "mlx-packed-groups-v1"),
    "mxfp8": PrecisionSpec("mxfp8", "mxfp8", 8, 32, 1, "mlx-packed-groups-v1"),
}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_batches(token_batches: Iterable[Iterable[int]]) -> tuple[tuple[int, ...], ...]:
    batches = tuple(tuple(int(token) for token in batch) for batch in token_batches)
    if not batches or any(not batch or any(token < 0 for token in batch) for batch in batches):
        raise ValueError("calibration token batches must contain non-negative token ids")
    return batches


@dataclass(frozen=True)
class MLXLayerAdapter:
    architecture: str
    modules: tuple[ModuleSpec, ...]
    runtime_paths: tuple[tuple[str, tuple[str, ...]], ...]
    fixed_parameter_count: int

    @classmethod
    def inspect(cls, model_path: Path) -> "MLXLayerAdapter":
        from mlx_lm import load
        from mlx.utils import tree_flatten

        model_path = model_path.expanduser().resolve()
        config = json.loads((model_path / "config.json").read_text(encoding="utf-8"))
        architecture = config.get("model_type")
        if architecture != "llama":
            raise ValueError(f"no validated mixed-precision adapter for {architecture!r}")
        model, _tokenizer = load(str(model_path), lazy=False)
        by_layer: dict[int, list[tuple[str, Any]]] = {}
        eligible_parameter_count = 0
        for path, module in model.named_modules():
            parts = path.split(".")
            if (
                len(parts) >= 4 and parts[:2] == ["model", "layers"]
                and parts[2].isdigit() and hasattr(module, "to_quantized")
                and hasattr(module, "weight") and module.weight.shape[-1] % 32 == 0
            ):
                layer = int(parts[2])
                by_layer.setdefault(layer, []).append((path, module))
                eligible_parameter_count += int(module.weight.size)
        expected_layers = int(config.get("num_hidden_layers", 0))
        if sorted(by_layer) != list(range(expected_layers)):
            raise ValueError("loaded Llama layers do not match the dense-layer adapter")
        modules: list[ModuleSpec] = []
        paths: list[tuple[str, tuple[str, ...]]] = []
        for layer, items in sorted(by_layer.items()):
            identifier = ModuleIdentifier.parse(f"layer.{layer}.transformer-block")
            modules.append(ModuleSpec(
                identifier=identifier,
                parameter_count=sum(int(module.weight.size) for _path, module in items),
                input_features=32,
            ))
            paths.append((identifier.canonical, tuple(sorted(path for path, _module in items))))
        total_parameters = sum(int(value.size) for _name, value in tree_flatten(model.parameters()))
        return cls(architecture, tuple(modules), tuple(paths), total_parameters - eligible_parameter_count)

    def paths_for(self, module_id: str) -> tuple[str, ...]:
        mapping = dict(self.runtime_paths)
        if module_id not in mapping:
            raise ValueError(f"unknown adapter module: {module_id}")
        return mapping[module_id]


class MLXLogitsKLEvaluator:
    evaluator_id = "mlx-parent-logits-kl-v1"
    metric_name = "mean_parent_to_trial_logits_kl"
    delta_semantics = "increase-is-worse"

    def __init__(self, *, model_path: Path, token_batches: Iterable[Iterable[int]], evidence_dir: Path) -> None:
        self.model_path = model_path.expanduser().resolve()
        self.token_batches = _canonical_batches(token_batches)
        self.evidence_dir = evidence_dir.expanduser().resolve()
        self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self.adapter = MLXLayerAdapter.inspect(self.model_path)
        self._reference_logits = self._logits(None, None)

    def _logits(self, module_id: str | None, precision: PrecisionSpec | None) -> tuple[Any, ...]:
        import mlx.core as mx
        from mlx_lm import load
        from mlx_lm.utils import quantize_model

        model, _tokenizer, config = load(str(self.model_path), lazy=False, return_config=True)
        if module_id is not None and precision is not None:
            selected = set(self.adapter.paths_for(module_id))

            def predicate(path: str, _module: Any) -> bool | dict[str, Any]:
                if path not in selected:
                    return False
                return {"group_size": precision.group_size, "bits": precision.bits, "mode": precision.mode}

            model, _config = quantize_model(
                model, config, precision.group_size, precision.bits,
                mode=precision.mode, quant_predicate=predicate,
            )
        outputs = []
        for batch in self.token_batches:
            logits = model(mx.array([batch])).astype(mx.float32)
            mx.eval(logits)
            outputs.append(logits)
        return tuple(outputs)

    def measure(self, module: ModuleSpec, precision: PrecisionSpec, calibration: CalibrationContract) -> EvaluationObservation | None:
        import mlx.core as mx

        if module not in self.adapter.modules or precision.identifier not in {"mxfp4", "mxfp8"}:
            return None
        trial_logits = self._logits(module.identifier.canonical, precision)
        deltas = []
        for reference, trial in zip(self._reference_logits, trial_logits, strict=True):
            probability = mx.softmax(reference, axis=-1)
            reference_log = reference - mx.logsumexp(reference, axis=-1, keepdims=True)
            trial_log = trial - mx.logsumexp(trial, axis=-1, keepdims=True)
            value = mx.mean(mx.sum(probability * (reference_log - trial_log), axis=-1))
            mx.eval(value)
            deltas.append(max(0.0, float(value.item())))
        delta = sum(deltas) / len(deltas)
        filename = f"{module.identifier.canonical}-{precision.identifier}.json"
        evidence = {
            "schema_version": 1, "evaluator_id": self.evaluator_id,
            "metric_name": self.metric_name, "module_id": module.identifier.canonical,
            "precision_id": precision.identifier, "delta": delta,
            "sample_count": len(self.token_batches),
            "token_count": sum(len(batch) for batch in self.token_batches),
            "calibration": {"dataset_id": calibration.dataset_id, "dataset_hash": calibration.dataset_hash, "seed": calibration.seed},
        }
        evidence_path = self.evidence_dir / filename
        evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return EvaluationObservation(
            delta=delta, sample_count=len(self.token_batches),
            token_count=sum(len(batch) for batch in self.token_batches),
            evidence_ref=str(evidence_path.relative_to(self.evidence_dir.parent)),
        )


def build_sensitivity_request(
    *, adapter: MLXLayerAdapter, model_path: Path,
    token_batches: Iterable[Iterable[int]], max_search_states: int,
    max_metric_delta: float | None = None,
) -> SensitivityRequest:
    model_path = model_path.expanduser().resolve()
    batches = _canonical_batches(token_batches)
    encoded = json.dumps(batches, separators=(",", ":")).encode("utf-8")
    tokenizer = model_path / "tokenizer.json"
    template = model_path / "chat_template.jinja"
    calibration = CalibrationContract(
        dataset_id="inline-token-batches-v1", dataset_hash=hashlib.sha256(encoded).hexdigest(),
        split="calibration", tokenizer_id=str(tokenizer), tokenizer_hash=_sha256_file(tokenizer),
        chat_template_hash=_sha256_file(template), seed=0,
        context_length=max(len(batch) for batch in batches), sample_budget=len(batches),
        token_budget=sum(len(batch) for batch in batches),
    )
    return SensitivityRequest(
        modules=adapter.modules, calibration=calibration, reference_precision=PRECISIONS["fp16"],
        trial_precisions=(PRECISIONS["mxfp4"], PRECISIONS["mxfp8"]),
        runtime=RuntimeAssignmentSupport(
            runtime_id="mlx-lm-callable-quant-predicate-v1",
            supported_modes=("mxfp4", "mxfp8"), supports_per_module_parameters=True,
            supports_mixed_modes=True, supports_float_fallback=True,
        ),
        protection_rules=(),
        search=SearchPolicy(max_search_states=max_search_states, max_predicted_metric_delta=max_metric_delta),
        fixed_bytes=adapter.fixed_parameter_count * 2,
    )


def apply_assignment(
    *, model_path: Path, output_path: Path, adapter: MLXLayerAdapter,
    assignments: dict[str, str],
) -> dict[str, Any]:
    from mlx_lm import load
    from mlx_lm.utils import quantize_model, save

    model_path = model_path.expanduser().resolve()
    output_path = output_path.expanduser().resolve()
    expected = {module.identifier.canonical for module in adapter.modules}
    if set(assignments) != expected:
        raise ValueError("assignment must cover every adapter module exactly once")
    if not set(assignments.values()) <= set(PRECISIONS):
        raise ValueError("assignment contains an unsupported precision")
    quantized = [value for value in assignments.values() if value != "fp16"]
    if not quantized:
        raise ValueError("assignment must quantize at least one module")
    if output_path.exists():
        raise ValueError(f"output already exists: {output_path}")
    runtime_assignment = {
        path: assignments[module_id]
        for module_id, paths in adapter.runtime_paths for path in paths
    }
    model, tokenizer, config = load(str(model_path), lazy=False, return_config=True)
    default = PRECISIONS[quantized[0]]

    def predicate(path: str, _module: Any) -> bool | dict[str, Any]:
        precision_id = runtime_assignment.get(path, "fp16")
        if precision_id == "fp16":
            return False
        precision = PRECISIONS[precision_id]
        return {"group_size": precision.group_size, "bits": precision.bits, "mode": precision.mode}

    model, config = quantize_model(
        model, config, default.group_size, default.bits,
        mode=default.mode, quant_predicate=predicate,
    )
    save(output_path, str(model_path), model, tokenizer, config)
    manifest = {
        "schema_version": 1, "adapter": adapter.architecture,
        "runtime": "mlx-lm-callable-quant-predicate-v1", "exact_parent": str(model_path),
        "candidate": str(output_path), "assignments": dict(sorted(assignments.items())),
        "runtime_paths": dict(sorted(runtime_assignment.items())),
    }
    (output_path / "mixed-precision-assignment.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    load(str(output_path), lazy=False)
    return manifest
