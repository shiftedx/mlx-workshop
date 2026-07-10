#!/usr/bin/env python3
"""Apply residual-direction orthogonalization to local MLX quantized models."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx_lm.utils import load_model, save_model
from mlx_lm.models.switch_layers import QuantizedSwitchLinear


LAYER_RE = re.compile(r"\.layers\.(\d+)\.")
ALLOWED_TARGETS = {"attention", "shared_down", "switch_down", "dense_down", "lm_head"}

COPY_PATTERNS = (
    "*.json",
    "*.jinja",
    "*.txt",
    "*.model",
    "*.tiktoken",
    "LICENSE",
    "README.md",
    "vocab.json",
    "merges.txt",
    "tokenizer.json",
    "tokenizer_config.json",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--direction", required=True, type=Path)
    parser.add_argument("--strength", default=1.0, type=float)
    parser.add_argument(
        "--targets",
        default="attention,shared_down,switch_down",
        help="Comma-separated: attention,shared_down,switch_down,dense_down,lm_head",
    )
    parser.add_argument(
        "--layers",
        default="",
        help="Optional destination layer filter, e.g. '28,32-38'. lm_head is not layer-filtered.",
    )
    parser.add_argument(
        "--direction-scope",
        choices=("global", "per-layer"),
        default="global",
        help="Use the saved global direction or saved per-layer signed directions.",
    )
    parser.add_argument(
        "--preserve-column-norm",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Preserve each edited weight vector's original norm (recommended default).",
    )
    parser.add_argument(
        "--expected-edited-modules",
        type=int,
        default=0,
        help="Fail unless exactly this many modules are edited; 0 disables the exact-count check.",
    )
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_hashes(source: Path) -> dict[str, str]:
    names = (
        "config.json",
        "tokenizer_config.json",
        "chat_template.jinja",
        "model.safetensors.index.json",
    )
    return {name: sha256(source / name) for name in names if (source / name).is_file()}


def copy_metadata(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for pattern in COPY_PATTERNS:
        for item in source.glob(pattern):
            if item.name.startswith("model") and item.suffix == ".safetensors":
                continue
            if item.is_file():
                shutil.copy2(item, output / item.name)


def parse_layers(spec: str) -> set[int] | None:
    if not spec.strip():
        return None
    layers: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            layers.update(range(int(start), int(end) + 1))
        else:
            layers.add(int(part))
    return layers


def layer_index(name: str) -> int | None:
    match = LAYER_RE.search(name)
    if not match:
        return None
    return int(match.group(1))


def normalize_np(direction: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(direction)
    if norm == 0:
        raise ValueError("Direction norm is zero")
    return direction / norm


def load_direction(path: Path) -> mx.array:
    data = np.load(path)
    direction = normalize_np(data["global_direction"].astype(np.float32))
    return mx.array(direction, dtype=mx.float32)


def load_layer_directions(path: Path) -> list[mx.array]:
    data = np.load(path)
    if "signed_directions" in data:
        directions = data["signed_directions"].astype(np.float32)
    else:
        directions = data["directions"].astype(np.float32)
        if "layer_scores" in data:
            scores = data["layer_scores"].astype(np.float32)
            for layer, score in enumerate(scores):
                if score < 0:
                    directions[layer] *= -1.0
    return [mx.array(normalize_np(direction), dtype=mx.float32) for direction in directions]


def target_kind(name: str, targets: set[str]) -> str | None:
    if "attention" in targets and (
        name.endswith(".self_attn.o_proj") or name.endswith(".linear_attn.out_proj")
    ):
        return "attention"
    if "shared_down" in targets and name.endswith(".mlp.shared_expert.down_proj"):
        return "shared_down"
    if "switch_down" in targets and name.endswith(".mlp.switch_mlp.down_proj"):
        return "switch_down"
    if "dense_down" in targets and name.endswith(".mlp.down_proj"):
        return "dense_down"
    if "lm_head" in targets and name.endswith(".lm_head"):
        return "lm_head"
    return None


def orthogonalize_2d(weight: mx.array, direction: mx.array, strength: float, preserve: bool) -> mx.array:
    weight = weight.astype(mx.float32)
    direction = direction.astype(mx.float32)
    if preserve:
        old_norm = mx.linalg.norm(weight, axis=0, keepdims=True)
    component = mx.sum(weight * direction[:, None], axis=0, keepdims=True)
    edited = weight - strength * direction[:, None] * component
    if preserve:
        new_norm = mx.linalg.norm(edited, axis=0, keepdims=True)
        edited = edited * (old_norm / mx.maximum(new_norm, mx.array(1e-6, dtype=mx.float32)))
    return edited.astype(mx.bfloat16)


def orthogonalize_input_2d(weight: mx.array, direction: mx.array, strength: float, preserve: bool) -> mx.array:
    weight = weight.astype(mx.float32)
    direction = direction.astype(mx.float32)
    if preserve:
        old_norm = mx.linalg.norm(weight, axis=1, keepdims=True)
    component = mx.sum(weight * direction[None, :], axis=1, keepdims=True)
    edited = weight - strength * component * direction[None, :]
    if preserve:
        new_norm = mx.linalg.norm(edited, axis=1, keepdims=True)
        edited = edited * (old_norm / mx.maximum(new_norm, mx.array(1e-6, dtype=mx.float32)))
    return edited.astype(mx.bfloat16)


def orthogonalize_3d(weight: mx.array, direction: mx.array, strength: float, preserve: bool) -> mx.array:
    weight = weight.astype(mx.float32)
    direction = direction.astype(mx.float32)
    if preserve:
        old_norm = mx.linalg.norm(weight, axis=1, keepdims=True)
    component = mx.sum(weight * direction[None, :, None], axis=1, keepdims=True)
    edited = weight - strength * direction[None, :, None] * component
    if preserve:
        new_norm = mx.linalg.norm(edited, axis=1, keepdims=True)
        edited = edited * (old_norm / mx.maximum(new_norm, mx.array(1e-6, dtype=mx.float32)))
    return edited.astype(mx.bfloat16)


def requantize_module(module, weight: mx.array) -> None:
    qweight, scales, *biases = mx.quantize(
        weight,
        group_size=module.group_size,
        bits=module.bits,
        mode=module.mode,
    )
    module.weight = qweight
    module.scales = scales
    module.biases = biases[0] if biases else None
    mx.eval(module.weight, module.scales)
    if module.biases is not None:
        mx.eval(module.biases)


def edit_quantized_linear(
    name: str,
    module,
    direction: mx.array,
    strength: float,
    preserve: bool,
    input_axis: bool = False,
) -> None:
    weight = mx.dequantize(
        module.weight,
        module.scales,
        module.biases,
        module.group_size,
        module.bits,
        module.mode,
    )
    if input_axis:
        edited = orthogonalize_input_2d(weight, direction, strength, preserve)
    elif isinstance(module, QuantizedSwitchLinear):
        edited = orthogonalize_3d(weight, direction, strength, preserve)
    else:
        edited = orthogonalize_2d(weight, direction, strength, preserve)
    requantize_module(module, edited)
    del weight, edited
    if hasattr(mx, "clear_cache"):
        mx.clear_cache()
    if hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
        mx.metal.clear_cache()


def update_config(output: Path, args: argparse.Namespace, edited: list[dict]) -> None:
    cfg_path = output / "config.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    cfg["abliteration"] = {
        "method": "residual_direction_weight_orthogonalization",
        "direction_file": str(args.direction),
        "strength": args.strength,
        "targets": args.targets,
        "layers": args.layers,
        "direction_scope": args.direction_scope,
        "preserve_column_norm": bool(args.preserve_column_norm),
        "expected_edited_modules": args.expected_edited_modules or None,
        "edited_modules": edited,
        "direction_sha256": sha256(args.direction),
        "source_hashes": source_hashes(args.source),
        "script_sha256": sha256(Path(__file__)),
        "quant_native_edit": True,
        "quant_native_edit_note": (
            "Each selected module was dequantized, edited in float32, and requantized "
            "once to its original MLX mode. Compare this artifact with its exact "
            "quantized parent; float-first edit then fresh quantization is preferred "
            "when host memory permits."
        ),
    }
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")


def update_readme(output: Path, args: argparse.Namespace, edited_count: int) -> None:
    readme = output / "README.md"
    text = readme.read_text(encoding="utf-8") if readme.exists() else f"# {output.name}\n"
    note = f"""

## Local Abliteration Experiment

This local variant applies residual-direction weight orthogonalization for over-refusal research.

- Direction: `{args.direction}`
- Strength: `{args.strength}`
- Targets: `{args.targets}`
- Layers: `{args.layers or 'all'}`
- Direction scope: `{args.direction_scope}`
- Preserve column norm: `{bool(args.preserve_column_norm)}`
- Edited modules: `{edited_count}`
- Quant-native edit: `true` (dequantize selected module, edit in float32, requantize once)

This model has not been uploaded to Hugging Face.
"""
    if "## Local Abliteration Experiment" not in text:
        text += note
    readme.write_text(text, encoding="utf-8")


def main() -> None:
    args = parse_args()
    args.source = args.source.expanduser().resolve()
    args.direction = args.direction.expanduser().resolve()
    args.output = args.output.expanduser().absolute()

    if not args.source.is_dir():
        raise FileNotFoundError(f"Source model directory does not exist: {args.source}")
    if not args.direction.is_file():
        raise FileNotFoundError(f"Direction file does not exist: {args.direction}")
    if args.strength <= 0:
        raise ValueError("--strength must be greater than zero")
    if args.expected_edited_modules < 0:
        raise ValueError("--expected-edited-modules must be non-negative")
    if (
        args.output == args.source
        or is_relative_to(args.output, args.source)
        or is_relative_to(args.source, args.output)
    ):
        raise ValueError("Source and output must be separate, non-nested directories")
    if args.direction == args.output or is_relative_to(args.direction, args.output):
        raise ValueError("Output must not contain or overwrite the direction artifact")
    output_exists = args.output.exists() or args.output.is_symlink()
    if output_exists and not args.overwrite:
        raise FileExistsError(f"{args.output} exists; pass --overwrite")
    if args.output.is_symlink() or (output_exists and not args.output.is_dir()):
        raise FileExistsError(f"Refusing to overwrite non-directory output: {args.output}")

    targets = {part.strip() for part in args.targets.split(",") if part.strip()}
    unknown_targets = targets - ALLOWED_TARGETS
    if not targets or unknown_targets:
        raise ValueError(
            "Invalid --targets; allowed values are "
            + ",".join(sorted(ALLOWED_TARGETS))
            + (f"; unknown: {','.join(sorted(unknown_targets))}" if unknown_targets else "")
        )
    source_config = json.loads((args.source / "config.json").read_text(encoding="utf-8"))
    if not (source_config.get("quantization") or source_config.get("quantization_config")):
        raise ValueError(
            "This MLX helper currently edits quantized modules only. For a float source, "
            "use a float-capable implementation, save the edited float model, then run "
            "fresh quantization."
        )

    layer_filter = parse_layers(args.layers)
    global_direction = load_direction(args.direction)
    layer_directions = load_layer_directions(args.direction) if args.direction_scope == "per-layer" else None
    model, _ = load_model(args.source, lazy=True, strict=True)

    edited = []
    for name, module in model.named_modules():
        kind = target_kind(name, targets)
        if kind is None:
            continue
        if not isinstance(module, (nn.QuantizedLinear, QuantizedSwitchLinear)):
            continue
        module_layer = layer_index(name)
        if kind != "lm_head" and layer_filter is not None and module_layer not in layer_filter:
            continue
        direction = global_direction
        if layer_directions is not None and module_layer is not None and module_layer < len(layer_directions):
            direction = layer_directions[module_layer]
        input_axis = kind == "lm_head"
        if input_axis:
            if isinstance(module, QuantizedSwitchLinear):
                continue
            in_dim = module.weight.shape[1]
            if in_dim != direction.shape[0]:
                continue
        else:
            out_dim = module.weight.shape[-2] if isinstance(module, QuantizedSwitchLinear) else module.weight.shape[0]
            if out_dim != direction.shape[0]:
                continue
        print(
            f"[edit] {name} kind={kind} layer={module_layer} "
            f"axis={'input' if input_axis else 'output'} bits={module.bits} mode={module.mode}"
        )
        edit_quantized_linear(
            name,
            module,
            direction,
            args.strength,
            args.preserve_column_norm,
            input_axis=input_axis,
        )
        edited.append(
            {
                "name": name,
                "kind": kind,
                "layer": module_layer,
                "axis": "input" if input_axis else "output",
                "bits": int(module.bits),
                "mode": module.mode,
            }
        )

    if not edited:
        raise RuntimeError("No compatible modules were edited; refusing to save a no-op artifact")
    if args.expected_edited_modules and len(edited) != args.expected_edited_modules:
        raise RuntimeError(
            f"Edited {len(edited)} modules, expected {args.expected_edited_modules}; "
            "refusing to save a structurally unexpected artifact"
        )

    if output_exists:
        shutil.rmtree(args.output)

    print(f"[save] {args.output}")
    copy_metadata(args.source, args.output)
    save_model(args.output, model, donate_model=True)
    update_config(args.output, args, edited)
    update_readme(args.output, args, len(edited))
    print(f"[done] edited_modules={len(edited)} output={args.output}")


if __name__ == "__main__":
    main()
