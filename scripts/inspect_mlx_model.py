#!/usr/bin/env python3
"""Inspect a local model and route it to host-supported MLX workflow adapters."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import shutil
from collections import Counter
from pathlib import Path
from typing import Any


HASH_FILES = (
    "config.json",
    "tokenizer_config.json",
    "chat_template.jinja",
    "model.safetensors.index.json",
    "generation_config.json",
    "preprocessor_config.json",
    "processor_config.json",
)

RESIDUAL_PATTERNS = {
    "attention": (
        ".self_attn.o_proj.weight",
        ".linear_attn.out_proj.weight",
        ".attention.wo.weight",
    ),
    "dense_down": (".mlp.down_proj.weight", ".feed_forward.w2.weight"),
    "shared_down": (".mlp.shared_expert.down_proj.weight",),
    "switch_down": (".mlp.switch_mlp.down_proj.weight",),
    "lm_head": (".lm_head.weight", "lm_head.weight"),
}


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def first(configs: list[dict[str, Any]], *names: str) -> Any:
    for config in configs:
        for name in names:
            value = config.get(name)
            if value is not None:
                return value
    return None


def summarize_quantization(value: Any) -> dict[str, Any] | None:
    """Return routing-relevant quantization metadata without copying huge maps."""
    if not isinstance(value, dict):
        return None
    preferred = (
        "mode",
        "bits",
        "group_size",
        "format",
        "quant_method",
        "quantization_status",
        "activation_scheme",
    )
    summary = {key: value[key] for key in preferred if key in value}
    summary["metadata_key_count"] = len(value)
    summary["module_override_count"] = sum(
        1 for key, item in value.items() if "." in key and isinstance(item, dict)
    )
    return summary


def mlx_lm_support(model_type: str | None) -> tuple[bool, str | None, str | None]:
    if not model_type:
        return False, None, "config has no model_type"
    try:
        from mlx_lm.utils import MODEL_REMAPPING
    except Exception as exc:
        return False, model_type, f"cannot import mlx_lm: {type(exc).__name__}: {exc}"
    mapped = MODEL_REMAPPING.get(model_type, model_type)
    try:
        supported = importlib.util.find_spec(f"mlx_lm.models.{mapped}") is not None
    except (ImportError, ModuleNotFoundError, ValueError) as exc:
        return False, mapped, f"MLX-LM model lookup failed: {exc}"
    return supported, mapped, None if supported else f"mlx_lm.models.{mapped} is unavailable"


def inspect_model(model: Path) -> dict[str, Any]:
    model = model.expanduser().resolve()
    failures: list[str] = []
    warnings: list[str] = []
    if not model.is_dir():
        return {
            "model": str(model),
            "status": "fail",
            "failures": ["model must be an inspected local directory"],
            "warnings": [],
        }

    config_path = model / "config.json"
    if not config_path.is_file():
        return {
            "model": str(model),
            "status": "fail",
            "failures": ["missing config.json"],
            "warnings": [],
        }
    config = read_json(config_path)
    text_config = config.get("text_config")
    configs = [config, text_config] if isinstance(text_config, dict) else [config]

    index_path = model / "model.safetensors.index.json"
    index = read_json(index_path) if index_path.is_file() else {}
    weight_map = index.get("weight_map") if isinstance(index.get("weight_map"), dict) else {}
    weight_keys = sorted(weight_map)
    shard_names = sorted(set(weight_map.values()))
    if weight_map:
        missing = [name for name in shard_names if not (model / name).is_file()]
        if missing:
            failures.append(f"missing {len(missing)} indexed shard(s): {', '.join(missing[:3])}")
    else:
        loose_shards = sorted(path.name for path in model.glob("*.safetensors"))
        if not loose_shards:
            failures.append("no safetensors index or loose safetensors files found")
        else:
            warnings.append("no model.safetensors.index.json; tensor-key routing is limited")
            shard_names = loose_shards

    dtype_counts: Counter[str] = Counter()
    header_keys: set[str] = set()
    validated_shards = 0
    if shard_names and not failures:
        try:
            from safetensors import safe_open

            for name in shard_names:
                with safe_open(str(model / name), framework="numpy") as handle:
                    keys = set(handle.keys())
                    header_keys.update(keys)
                    for key in keys:
                        dtype_counts[str(handle.get_slice(key).get_dtype())] += 1
                validated_shards += 1
            if weight_map:
                missing_header_keys = set(weight_map) - header_keys
                if missing_header_keys:
                    failures.append(
                        f"{len(missing_header_keys)} indexed tensor key(s) are absent from shard headers"
                    )
            else:
                weight_keys = sorted(header_keys)
        except Exception as exc:
            failures.append(f"cannot validate safetensors headers: {type(exc).__name__}: {exc}")

    model_type = first(configs, "model_type")
    architectures = config.get("architectures") or []
    supported, mapped_type, support_error = mlx_lm_support(model_type)
    if support_error:
        warnings.append(support_error)

    quantization = first(configs, "quantization", "quantization_config")
    quantization_summary = summarize_quantization(quantization)
    quantized_keys = [
        key
        for key in weight_keys
        if key.endswith((".scales", ".biases", ".qweight", ".qzeros", ".g_idx"))
    ]
    fp8_scale_keys = [
        key for key in weight_keys if "weight_scale" in key or "scale_inv" in key
    ]
    quantization_text = json.dumps(quantization_summary or {}, sort_keys=True).lower()
    declares_native_fp8 = (
        "float-quantized" in quantization_text
        or "w8a8_fp8" in quantization_text
        or ("fp8" in quantization_text and "mxfp" not in quantization_text)
        or any("F8" in dtype.upper() or "FP8" in dtype.upper() for dtype in dtype_counts)
    )
    if fp8_scale_keys or declares_native_fp8:
        source_state = "native-fp8-scaled"
    elif isinstance(quantization, dict) or quantized_keys:
        source_state = "quantized"
    else:
        source_state = "float-candidate"

    num_experts = first(
        configs,
        "num_experts",
        "num_local_experts",
        "n_routed_experts",
        "num_experts_per_tok",
    )
    architecture_kind = "moe" if isinstance(num_experts, int) and num_experts > 1 else "dense-or-unknown"
    vision_config = config.get("vision_config")
    vision_weight_count = sum(
        1 for key in weight_keys if "vision" in key or "visual" in key or key.startswith("vision_tower.")
    )
    has_vision = bool(vision_config or vision_weight_count)
    mtp_layers = first(configs, "mtp_num_hidden_layers", "num_nextn_predict_layers") or 0
    has_mtp_sidecar = (model / "mtp.safetensors").is_file()

    residual_counts: dict[str, int] = {}
    matched_residual_keys: set[str] = set()
    for kind, suffixes in RESIDUAL_PATTERNS.items():
        matches = [key for key in weight_keys if any(key.endswith(suffix) for suffix in suffixes)]
        residual_counts[kind] = len(matches)
        matched_residual_keys.update(matches)

    qwen35_types = {"qwen3_5", "qwen3_5_moe", "qwen3_5_moe_text"}
    activation_adapter = (
        "qwen35-hybrid-completion-v1" if model_type in qwen35_types else "adapter-required"
    )
    streaming_adapter = (
        "qwen35-streaming-v1" if model_type in qwen35_types else None
    )

    conversion_route: dict[str, Any]
    if source_state == "float-candidate" and supported:
        conversion_route = {
            "default": "upstream-mlx-lm-convert",
            "fallback_adapter": streaming_adapter,
            "allowed": True,
        }
    elif source_state == "native-fp8-scaled":
        conversion_route = {
            "default": "format-aware-fp8-dequantization-adapter-required",
            "fallback_adapter": None,
            "allowed": False,
        }
    elif source_state == "quantized":
        conversion_route = {
            "default": "do-not-requantize",
            "fallback_adapter": None,
            "allowed": False,
        }
    else:
        conversion_route = {
            "default": "architecture-adapter-required",
            "fallback_adapter": None,
            "allowed": False,
        }

    total_disk_bytes = sum(
        (model / name).stat().st_size for name in shard_names if (model / name).is_file()
    )
    disk = shutil.disk_usage(model)
    hashes = {name: sha256(model / name) for name in HASH_FILES if (model / name).is_file()}

    result = {
        "model": str(model),
        "status": "pass" if not failures else "fail",
        "identity": {
            "model_type": model_type,
            "mlx_lm_model_type": mapped_type,
            "architectures": architectures,
            "architecture_kind": architecture_kind,
            "num_hidden_layers": first(configs, "num_hidden_layers", "n_layer", "num_layers"),
            "hidden_size": first(configs, "hidden_size", "d_model", "dim"),
            "num_experts": num_experts,
        },
        "source": {
            "state": source_state,
            "quantization": quantization_summary,
            "indexed_tensors": len(weight_keys),
            "indexed_shards": len(shard_names),
            "quantized_tensor_metadata_keys": len(quantized_keys),
            "fp8_scale_keys": len(fp8_scale_keys),
            "tensor_dtypes": dict(sorted(dtype_counts.items())),
            "validated_shard_headers": validated_shards,
            "disk_bytes": total_disk_bytes,
            "hashes": hashes,
        },
        "capabilities": {
            "mlx_lm_supported": supported,
            "vision": has_vision,
            "vision_tensor_count": vision_weight_count,
            "mtp_layers_advertised": mtp_layers,
            "mtp_sidecar": has_mtp_sidecar,
            "residual_writer_counts": residual_counts,
            "matched_residual_writers": len(matched_residual_keys),
        },
        "routing": {
            "conversion": conversion_route,
            "activation_capture_adapter": activation_adapter,
            "quant_native_weight_edit": "common-residual-writers-v1"
            if matched_residual_keys and source_state == "quantized"
            else "adapter-required",
            "vision_graft": "lineage-proof-required" if has_vision else "not-advertised",
            "mtplx": "inspect-required" if (has_mtp_sidecar or mtp_layers) else "not-advertised",
        },
        "host": {
            "free_disk_bytes": disk.free,
            "total_disk_bytes": disk.total,
        },
        "failures": failures,
        "warnings": warnings,
    }
    return result


def print_human(result: dict[str, Any]) -> None:
    print(f"Model: {result['model']}")
    print(f"Status: {result['status']}")
    if result["status"] == "fail" and "identity" not in result:
        for failure in result.get("failures", []):
            print(f"FAIL: {failure}")
        return
    identity = result["identity"]
    source = result["source"]
    capabilities = result["capabilities"]
    routing = result["routing"]
    print(
        f"Architecture: {identity['model_type']} -> {identity['mlx_lm_model_type']} "
        f"({identity['architecture_kind']})"
    )
    print(f"Source state: {source['state']}")
    print(
        f"Capabilities: mlx_lm={capabilities['mlx_lm_supported']} "
        f"vision={capabilities['vision']} mtp_sidecar={capabilities['mtp_sidecar']}"
    )
    print(f"Residual writers: {capabilities['residual_writer_counts']}")
    print(f"Conversion route: {routing['conversion']['default']}")
    print(f"Activation adapter: {routing['activation_capture_adapter']}")
    for warning in result.get("warnings", []):
        print(f"WARN: {warning}")
    for failure in result.get("failures", []):
        print(f"FAIL: {failure}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    result = inspect_model(args.model)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_human(result)
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
