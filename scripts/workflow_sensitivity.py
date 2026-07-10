"""Measured, architecture-neutral mixed-precision sensitivity and search.

This module does not load or mutate a model. Architecture adapters provide canonical
module identifiers and an evaluator provides every metric delta used by the search.
Candidate deltas are explicitly additive predictions over those measurements.
"""

from __future__ import annotations

import hashlib
import itertools
import math
import re
from dataclasses import asdict, dataclass
from typing import Any, Protocol


IDENTIFIER_PART = re.compile(r"^[a-z][a-z0-9_-]*$")


@dataclass(frozen=True, order=True)
class ModuleIdentifier:
    scope: str
    role: str
    layer: int | None = None
    ordinal: int | None = None

    @classmethod
    def parse(cls, value: str) -> "ModuleIdentifier":
        parts = value.split(".")
        if len(parts) == 2 and parts[0] == "global":
            return cls(scope="global", role=parts[1])
        if len(parts) >= 3 and parts[0] == "layer" and parts[1].isdigit():
            role_parts = parts[2:]
            ordinal = None
            if len(role_parts) > 1 and role_parts[-1].isdigit():
                ordinal = int(role_parts.pop())
            return cls(scope="layer", layer=int(parts[1]), role=".".join(role_parts), ordinal=ordinal)
        raise ValueError(f"invalid canonical module identifier: {value}")

    def __post_init__(self) -> None:
        if self.scope not in {"global", "layer"}:
            raise ValueError("module scope must be global or layer")
        if self.scope == "global" and (self.layer is not None or self.ordinal is not None):
            raise ValueError("global module identifiers cannot have layer or ordinal")
        if self.scope == "layer" and (self.layer is None or self.layer < 0):
            raise ValueError("layer module identifiers require a non-negative layer")
        if not self.role or not all(IDENTIFIER_PART.fullmatch(part) for part in self.role.split(".")):
            raise ValueError(f"invalid architecture-neutral role: {self.role}")
        if self.ordinal is not None and self.ordinal < 0:
            raise ValueError("module ordinal must be non-negative")

    @property
    def canonical(self) -> str:
        if self.scope == "global":
            return f"global.{self.role}"
        suffix = f".{self.ordinal}" if self.ordinal is not None else ""
        return f"layer.{self.layer}.{self.role}{suffix}"


@dataclass(frozen=True)
class ModuleSpec:
    identifier: ModuleIdentifier
    parameter_count: int
    input_features: int
    has_quantized_implementation: bool = True

    def __post_init__(self) -> None:
        if self.parameter_count <= 0 or self.input_features <= 0:
            raise ValueError("module sizes must be positive")


@dataclass(frozen=True)
class CalibrationContract:
    dataset_id: str
    dataset_hash: str
    split: str
    tokenizer_id: str
    tokenizer_hash: str
    chat_template_hash: str
    seed: int
    context_length: int
    sample_budget: int
    token_budget: int

    def __post_init__(self) -> None:
        declared = (
            self.dataset_id,
            self.dataset_hash,
            self.split,
            self.tokenizer_id,
            self.tokenizer_hash,
            self.chat_template_hash,
        )
        if not all(isinstance(value, str) and value.strip() for value in declared):
            raise ValueError("calibration dataset, tokenizer, template, and hashes must be declared")
        if self.seed < 0 or min(
            self.context_length, self.sample_budget, self.token_budget
        ) <= 0:
            raise ValueError("calibration seed and budgets are invalid")


@dataclass(frozen=True)
class PrecisionSpec:
    identifier: str
    mode: str
    bits: int
    group_size: int | None
    bytes_per_group_overhead: int
    size_model: str

    def __post_init__(self) -> None:
        if not IDENTIFIER_PART.fullmatch(self.identifier):
            raise ValueError(f"invalid precision identifier: {self.identifier}")
        if not self.mode or self.bits <= 0 or self.bytes_per_group_overhead < 0:
            raise ValueError("precision mode, bits, and overhead must be declared")
        if self.mode == "float" and self.group_size is not None:
            raise ValueError("float reference precision cannot have a group size")
        if self.mode != "float" and (self.group_size is None or self.group_size <= 0):
            raise ValueError("quantized precision requires a positive group size")
        if not self.size_model:
            raise ValueError("precision size model must be declared")


@dataclass(frozen=True)
class RuntimeAssignmentSupport:
    runtime_id: str
    supported_modes: tuple[str, ...]
    supports_per_module_parameters: bool
    supports_mixed_modes: bool
    supports_float_fallback: bool


@dataclass(frozen=True)
class ProtectionRule:
    name: str
    roles: tuple[str, ...] = ()
    module_ids: tuple[str, ...] = ()
    layer_indices: tuple[int, ...] = ()

    def matches(self, identifier: ModuleIdentifier) -> bool:
        return (
            identifier.role in self.roles
            or identifier.canonical in self.module_ids
            or (identifier.layer is not None and identifier.layer in self.layer_indices)
        )


@dataclass(frozen=True)
class SearchPolicy:
    max_search_states: int
    max_predicted_metric_delta: float | None = None
    max_predicted_bytes: int | None = None

    def __post_init__(self) -> None:
        if self.max_search_states <= 0:
            raise ValueError("search-state budget must be positive")
        if self.max_predicted_bytes is not None and self.max_predicted_bytes <= 0:
            raise ValueError("predicted-byte budget must be positive")
        if self.max_predicted_metric_delta is not None and not math.isfinite(
            self.max_predicted_metric_delta
        ):
            raise ValueError("metric-delta budget must be finite")


@dataclass(frozen=True)
class SensitivityRequest:
    modules: tuple[ModuleSpec, ...]
    calibration: CalibrationContract
    reference_precision: PrecisionSpec
    trial_precisions: tuple[PrecisionSpec, ...]
    runtime: RuntimeAssignmentSupport
    protection_rules: tuple[ProtectionRule, ...]
    search: SearchPolicy
    fixed_bytes: int = 0


@dataclass(frozen=True)
class EvaluationObservation:
    delta: float
    sample_count: int
    token_count: int
    evidence_ref: str


class SensitivityEvaluator(Protocol):
    evaluator_id: str
    metric_name: str
    delta_semantics: str

    def measure(
        self,
        module: ModuleSpec,
        precision: PrecisionSpec,
        calibration: CalibrationContract,
    ) -> EvaluationObservation | None: ...


@dataclass(frozen=True)
class ModuleMeasurement:
    module_id: str
    precision_id: str
    metric_name: str
    delta: float
    sample_count: int
    token_count: int
    evaluator_id: str
    evidence_ref: str


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    assignments: tuple[tuple[str, str], ...]
    predicted_bytes: int
    predicted_metric_delta: float
    metric_name: str
    prediction_model: str = "additive-measured-module-deltas-v1"
    size_prediction_model: str = "declared-packed-bits-plus-group-overhead-v1"


@dataclass(frozen=True)
class UnsupportedReason:
    code: str
    message: str


@dataclass(frozen=True)
class SensitivityResult:
    status: str
    evaluator_id: str | None
    metric_name: str | None
    calibration: CalibrationContract | None = None
    runtime_id: str | None = None
    reference_precision_id: str | None = None
    trial_precision_ids: tuple[str, ...] = ()
    measurements: tuple[ModuleMeasurement, ...] = ()
    candidates: tuple[Candidate, ...] = ()
    frontier: tuple[Candidate, ...] = ()
    protected_modules: tuple[tuple[str, tuple[str, ...]], ...] = ()
    unsupported: UnsupportedReason | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _unsupported(
    code: str,
    message: str,
    *,
    request: SensitivityRequest,
    evaluator: SensitivityEvaluator | None,
) -> SensitivityResult:
    return SensitivityResult(
        status="unsupported",
        evaluator_id=getattr(evaluator, "evaluator_id", None),
        metric_name=getattr(evaluator, "metric_name", None),
        calibration=request.calibration,
        runtime_id=request.runtime.runtime_id,
        reference_precision_id=request.reference_precision.identifier,
        trial_precision_ids=tuple(item.identifier for item in request.trial_precisions),
        unsupported=UnsupportedReason(code, message),
    )


def _predicted_module_bytes(module: ModuleSpec, precision: PrecisionSpec) -> int:
    packed_bytes = math.ceil(module.parameter_count * precision.bits / 8)
    if precision.group_size is None:
        return packed_bytes
    group_count = math.ceil(module.parameter_count / precision.group_size)
    return packed_bytes + group_count * precision.bytes_per_group_overhead


def _candidate_id(assignments: tuple[tuple[str, str], ...]) -> str:
    encoded = "|".join(f"{module}={precision}" for module, precision in assignments)
    return "candidate-" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:12]


def _pareto(candidates: tuple[Candidate, ...]) -> tuple[Candidate, ...]:
    frontier = []
    for candidate in candidates:
        dominated = any(
            other is not candidate
            and other.predicted_bytes <= candidate.predicted_bytes
            and other.predicted_metric_delta <= candidate.predicted_metric_delta
            and (
                other.predicted_bytes < candidate.predicted_bytes
                or other.predicted_metric_delta < candidate.predicted_metric_delta
            )
            for other in candidates
        )
        if not dominated:
            frontier.append(candidate)
    return tuple(sorted(frontier, key=lambda item: (item.predicted_bytes, item.predicted_metric_delta)))


def analyze_sensitivity(
    request: SensitivityRequest,
    evaluator: SensitivityEvaluator | None,
) -> SensitivityResult:
    """Measure per-module deltas and search the deterministic precision frontier."""
    def unsupported(code: str, message: str) -> SensitivityResult:
        return _unsupported(code, message, request=request, evaluator=evaluator)

    if evaluator is None:
        return unsupported("evaluator-unavailable", "No sensitivity evaluator was supplied.")
    if not request.modules or not request.trial_precisions:
        return unsupported("search-space-empty", "Modules and trial precisions are required.")
    if request.reference_precision.mode != "float":
        return unsupported("reference-format-unsupported", "The reference precision must be float.")
    if evaluator.delta_semantics != "increase-is-worse":
        return unsupported(
            "metric-semantics-unsupported",
            "Evaluator deltas must be normalized so an increase is worse.",
        )
    if not evaluator.evaluator_id or not evaluator.metric_name:
        return unsupported("evaluator-metadata-missing", "Evaluator identity and metric are required.")
    if not request.runtime.supports_per_module_parameters:
        return unsupported(
            "per-module-assignments-unsupported",
            f"Runtime {request.runtime.runtime_id} cannot express per-module assignments.",
        )
    trials = tuple(sorted(request.trial_precisions, key=lambda item: item.identifier))
    if any(item.mode not in request.runtime.supported_modes for item in trials):
        return unsupported(
            "precision-mode-unsupported",
            f"Runtime {request.runtime.runtime_id} does not support every requested mode.",
        )
    if len({item.mode for item in trials}) > 1 and not request.runtime.supports_mixed_modes:
        return unsupported(
            "mixed-modes-unsupported",
            f"Runtime {request.runtime.runtime_id} cannot mix quantization modes.",
        )

    modules = tuple(sorted(request.modules, key=lambda item: item.identifier.canonical))
    if len({item.identifier.canonical for item in modules}) != len(modules):
        raise ValueError("module identifiers must be unique")
    protected: dict[str, tuple[str, ...]] = {}
    option_map: dict[str, tuple[PrecisionSpec, ...]] = {}
    for module in modules:
        reasons = tuple(
            rule.name for rule in request.protection_rules if rule.matches(module.identifier)
        )
        if reasons:
            protected[module.identifier.canonical] = reasons
            if not request.runtime.supports_float_fallback:
                return unsupported(
                    "float-fallback-unsupported",
                    f"Protected module {module.identifier.canonical} cannot remain at reference precision.",
                )
            option_map[module.identifier.canonical] = (request.reference_precision,)
            continue
        eligible = tuple(
            precision
            for precision in trials
            if module.has_quantized_implementation
            and precision.group_size is not None
            and module.input_features % precision.group_size == 0
        )
        option_map[module.identifier.canonical] = (request.reference_precision, *eligible)

    if all(len(options) == 1 for options in option_map.values()):
        return unsupported(
            "no-assignable-modules",
            "No module is eligible for any requested precision under the runtime rules.",
        )
    search_states = math.prod(len(options) for options in option_map.values())
    if search_states > request.search.max_search_states:
        return unsupported(
            "search-budget-exceeded",
            f"Search requires {search_states} states but the declared budget is "
            f"{request.search.max_search_states}.",
        )

    measurements: list[ModuleMeasurement] = []
    delta_by_assignment: dict[tuple[str, str], float] = {}
    for module in modules:
        module_id = module.identifier.canonical
        for precision in option_map[module_id][1:]:
            observation = evaluator.measure(module, precision, request.calibration)
            if observation is None:
                return unsupported(
                    "evaluator-evidence-missing",
                    f"No evaluator evidence for {module_id} at {precision.identifier}.",
                )
            if (
                not math.isfinite(observation.delta)
                or observation.sample_count <= 0
                or observation.token_count <= 0
                or observation.sample_count > request.calibration.sample_budget
                or observation.token_count > request.calibration.token_budget
                or not observation.evidence_ref
            ):
                return unsupported(
                    "evaluator-evidence-invalid",
                    f"Evaluator evidence violates the calibration contract for {module_id}.",
                )
            measurement = ModuleMeasurement(
                module_id=module_id,
                precision_id=precision.identifier,
                metric_name=evaluator.metric_name,
                delta=observation.delta,
                sample_count=observation.sample_count,
                token_count=observation.token_count,
                evaluator_id=evaluator.evaluator_id,
                evidence_ref=observation.evidence_ref,
            )
            measurements.append(measurement)
            delta_by_assignment[(module_id, precision.identifier)] = observation.delta

    precision_by_id = {
        item.identifier: item for item in (request.reference_precision, *trials)
    }
    candidates: list[Candidate] = []
    module_ids = tuple(option_map)
    for selected in itertools.product(*(option_map[module_id] for module_id in module_ids)):
        assignments = tuple(
            (module_id, precision.identifier)
            for module_id, precision in zip(module_ids, selected, strict=True)
        )
        predicted_delta = math.fsum(
            delta_by_assignment.get((module_id, precision_id), 0.0)
            for module_id, precision_id in assignments
        )
        predicted_bytes = request.fixed_bytes + sum(
            _predicted_module_bytes(module, precision_by_id[precision_id])
            for module, (_module_id, precision_id) in zip(modules, assignments, strict=True)
        )
        if (
            request.search.max_predicted_metric_delta is not None
            and predicted_delta > request.search.max_predicted_metric_delta
        ):
            continue
        if (
            request.search.max_predicted_bytes is not None
            and predicted_bytes > request.search.max_predicted_bytes
        ):
            continue
        candidates.append(
            Candidate(
                candidate_id=_candidate_id(assignments),
                assignments=assignments,
                predicted_bytes=predicted_bytes,
                predicted_metric_delta=predicted_delta,
                metric_name=evaluator.metric_name,
            )
        )
    ordered_candidates = tuple(
        sorted(
            candidates,
            key=lambda item: (
                item.predicted_bytes,
                item.predicted_metric_delta,
                item.candidate_id,
            ),
        )
    )
    if not ordered_candidates:
        return unsupported(
            "candidate-budget-empty",
            "No measured assignment satisfies the declared search constraints.",
        )
    return SensitivityResult(
        status="supported",
        evaluator_id=evaluator.evaluator_id,
        metric_name=evaluator.metric_name,
        calibration=request.calibration,
        runtime_id=request.runtime.runtime_id,
        reference_precision_id=request.reference_precision.identifier,
        trial_precision_ids=tuple(item.identifier for item in trials),
        measurements=tuple(measurements),
        candidates=ordered_candidates,
        frontier=_pareto(ordered_candidates),
        protected_modules=tuple(sorted(protected.items())),
    )
