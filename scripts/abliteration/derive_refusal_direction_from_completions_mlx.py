#!/usr/bin/env python3
"""Derive a completion-position refusal direction for Qwen3.5-MoE MLX models."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np
from mlx_lm import generate, load
from mlx_lm.models.base import create_attention_mask, create_ssm_mask
from mlx_lm.sample_utils import make_sampler

from derive_refusal_direction_mlx import BENIGN_PROMPTS, REFUSAL_PROMPTS


REFUSAL_MARKERS = [
    "i can't",
    "i cannot",
    "i can’t",
    "i'm sorry",
    "i am sorry",
    "sorry,",
    "unable to",
    "not able to",
    "cannot assist",
    "can't assist",
    "can't help",
    "cannot help",
    "won't help",
    "not provide",
    "not appropriate",
    "against policy",
    "i must decline",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--top-k-layers", default=8, type=int)
    parser.add_argument("--min-layer", default=10, type=int)
    parser.add_argument("--max-prompts", default=0, type=int)
    parser.add_argument("--max-generation-tokens", default=96, type=int)
    parser.add_argument("--completion-token-window", default=48, type=int)
    parser.add_argument("--projected", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--min-refusal-marker-rate", default=0.8, type=float)
    parser.add_argument("--max-benign-refusal-marker-rate", default=0.2, type=float)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def render_prompt(tokenizer, content: str) -> str:
    messages = [{"role": "user", "content": content}]
    try:
        return tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=False,
            enable_thinking=False,
        )
    except TypeError:
        return tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=False,
        )


def clear_mlx_cache() -> None:
    if hasattr(mx, "clear_cache"):
        mx.clear_cache()
    elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
        mx.metal.clear_cache()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_hashes(root: Path, names: tuple[str, ...]) -> dict[str, str]:
    return {
        name: sha256(root / name)
        for name in names
        if (root / name).is_file()
    }


def package_versions() -> dict[str, str]:
    versions = {"python": sys.version.split()[0]}
    for name in ("mlx", "mlx-lm", "transformers", "safetensors"):
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = "missing"
    return versions


def normalize(v: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(v)
    if norm == 0:
        return v
    return v / norm


def is_refusal(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in REFUSAL_MARKERS)


def completion_mean_states(model, token_ids: list[int], positions: list[int]) -> np.ndarray:
    lm = model.language_model
    text_model = lm.model
    inputs = mx.array([token_ids])
    hidden_states = text_model.embed_tokens(inputs)
    cache = [None] * len(text_model.layers)
    fa_mask = create_attention_mask(hidden_states, cache[text_model.fa_idx])
    ssm_mask = create_ssm_mask(hidden_states, cache[text_model.ssm_idx])
    pos = mx.array(positions)

    states = []
    for layer, layer_cache in zip(text_model.layers, cache):
        mask = ssm_mask if layer.is_linear else fa_mask
        hidden_states = layer(hidden_states, mask=mask, cache=layer_cache)
        selected = mx.mean(hidden_states[0, pos, :].astype(mx.float32), axis=0)
        mx.eval(selected)
        states.append(np.array(selected))

    clear_mlx_cache()
    return np.stack(states, axis=0)


def generate_completion(model, tokenizer, prompt: str, max_tokens: int, sampler) -> tuple[str, list[int], list[int]]:
    rendered = render_prompt(tokenizer, prompt)
    prompt_ids = tokenizer.encode(rendered)
    completion = generate(
        model,
        tokenizer,
        prompt=rendered,
        max_tokens=max_tokens,
        sampler=sampler,
        verbose=False,
    )
    completion_ids = tokenizer.encode(completion, add_special_tokens=False)
    return completion, prompt_ids, completion_ids


def collect_group(
    label: str,
    model,
    tokenizer,
    prompts: list[str],
    max_generation_tokens: int,
    completion_token_window: int,
    sampler,
) -> tuple[np.ndarray, list[dict]]:
    states = []
    meta = []
    for index, prompt in enumerate(prompts, start=1):
        completion, prompt_ids, completion_ids = generate_completion(
            model,
            tokenizer,
            prompt,
            max_generation_tokens,
            sampler,
        )
        completion_ids = completion_ids[:completion_token_window]
        if not completion_ids:
            raise ValueError(f"{label} prompt {index} produced no completion tokens")
        full_ids = prompt_ids + completion_ids
        positions = list(range(len(prompt_ids), len(full_ids)))
        item_states = completion_mean_states(model, full_ids, positions)
        states.append(item_states)
        item = {
            "index": index,
            "prompt_tokens": len(prompt_ids),
            "completion_tokens_used": len(completion_ids),
            "refusal_marker": is_refusal(completion),
        }
        meta.append(item)
        print(
            f"[{label}] {index:02d}/{len(prompts)} "
            f"prompt_tokens={len(prompt_ids)} completion_tokens={len(completion_ids)} "
            f"refusal_marker={item['refusal_marker']}"
        )
    return np.stack(states, axis=0), meta


def projected_directions(refusal_mean: np.ndarray, benign_mean: np.ndarray, projected: bool) -> np.ndarray:
    raw = refusal_mean - benign_mean
    if projected:
        adjusted = []
        for layer in range(raw.shape[0]):
            harmless = normalize(benign_mean[layer])
            adjusted.append(raw[layer] - np.dot(raw[layer], harmless) * harmless)
        raw = np.stack(adjusted, axis=0)
    return np.stack([normalize(v) for v in raw], axis=0)


def main() -> None:
    args = parse_args()
    args.model = args.model.expanduser().resolve()
    args.output = args.output.expanduser().absolute()
    output_npz = args.output if args.output.suffix == ".npz" else args.output.with_suffix(".npz")
    output_json = output_npz.with_suffix(".json")

    if not args.model.is_dir():
        raise FileNotFoundError(f"Model directory does not exist: {args.model}")
    if args.top_k_layers <= 0 or args.min_layer < 0:
        raise ValueError("--top-k-layers must be positive and --min-layer non-negative")
    if args.max_generation_tokens <= 0 or args.completion_token_window <= 0:
        raise ValueError("Generation and completion windows must be positive")
    if not 0.0 <= args.min_refusal_marker_rate <= 1.0:
        raise ValueError("--min-refusal-marker-rate must be between 0 and 1")
    if not 0.0 <= args.max_benign_refusal_marker_rate <= 1.0:
        raise ValueError("--max-benign-refusal-marker-rate must be between 0 and 1")
    try:
        output_npz.relative_to(args.model)
    except ValueError:
        pass
    else:
        raise ValueError("Direction output must not be written inside the model source")
    existing = [path for path in (output_npz, output_json) if path.exists()]
    if existing and not args.overwrite:
        raise FileExistsError(
            "Direction output exists; choose a new run path or pass --overwrite: "
            + ", ".join(str(path) for path in existing)
        )

    model, tokenizer, config = load(str(args.model), lazy=True, return_config=True)
    sampler = make_sampler(temp=0.0)

    refusal_prompts = REFUSAL_PROMPTS
    benign_prompts = BENIGN_PROMPTS
    if args.max_prompts and args.max_prompts > 0:
        refusal_prompts = refusal_prompts[: args.max_prompts]
        benign_prompts = benign_prompts[: args.max_prompts]

    print(f"[load] {args.model}")
    print(f"[prompts] refusal={len(refusal_prompts)} benign={len(benign_prompts)}")
    print(
        f"[method] completion_mean projected={args.projected} "
        f"window={args.completion_token_window}"
    )

    refusal_arr, refusal_meta = collect_group(
        "refusal",
        model,
        tokenizer,
        refusal_prompts,
        args.max_generation_tokens,
        args.completion_token_window,
        sampler,
    )
    benign_arr, benign_meta = collect_group(
        "benign",
        model,
        tokenizer,
        benign_prompts,
        args.max_generation_tokens,
        args.completion_token_window,
        sampler,
    )

    refusal_marker_rate = sum(
        1 for item in refusal_meta if item["refusal_marker"]
    ) / len(refusal_meta)
    benign_refusal_marker_rate = sum(
        1 for item in benign_meta if item["refusal_marker"]
    ) / len(benign_meta)
    if refusal_marker_rate < args.min_refusal_marker_rate:
        raise RuntimeError(
            f"Refusal marker rate {refusal_marker_rate:.1%} is below the required "
            f"{args.min_refusal_marker_rate:.1%}; inspect completions before deriving."
        )
    if benign_refusal_marker_rate > args.max_benign_refusal_marker_rate:
        raise RuntimeError(
            f"Benign refusal marker rate {benign_refusal_marker_rate:.1%} exceeds the "
            f"allowed {args.max_benign_refusal_marker_rate:.1%}."
        )

    refusal_mean = refusal_arr.mean(axis=0)
    benign_mean = benign_arr.mean(axis=0)
    directions = projected_directions(refusal_mean, benign_mean, args.projected)

    layer_scores = []
    for layer in range(directions.shape[0]):
        direction = directions[layer]
        refusal_proj = refusal_arr[:, layer, :] @ direction
        benign_proj = benign_arr[:, layer, :] @ direction
        pooled_std = refusal_proj.std() + benign_proj.std() + 1e-6
        score = float((refusal_proj.mean() - benign_proj.mean()) / pooled_std)
        layer_scores.append(score)

    eligible = [
        layer
        for layer in range(directions.shape[0])
        if layer >= args.min_layer and np.isfinite(layer_scores[layer])
    ]
    selected = sorted(
        eligible,
        key=lambda layer: abs(layer_scores[layer]),
        reverse=True,
    )[: args.top_k_layers]
    selected = sorted(selected)

    signed_directions = directions.copy()
    for layer in range(signed_directions.shape[0]):
        if layer_scores[layer] < 0:
            signed_directions[layer] *= -1.0
    global_direction = normalize(np.mean(signed_directions[selected], axis=0))

    output_npz.parent.mkdir(parents=True, exist_ok=True)
    if args.overwrite:
        for path in (output_npz, output_json):
            if path.exists():
                path.unlink()
    np.savez_compressed(
        output_npz,
        directions=directions.astype(np.float32),
        signed_directions=signed_directions.astype(np.float32),
        global_direction=global_direction.astype(np.float32),
        layer_scores=np.array(layer_scores, dtype=np.float32),
        selected_layers=np.array(selected, dtype=np.int32),
        refusal_mean=refusal_mean.astype(np.float32),
        benign_mean=benign_mean.astype(np.float32),
    )

    meta = {
        "model": str(args.model),
        "model_type": config.get("model_type"),
        "text_model_type": config.get("text_config", {}).get("model_type"),
        "method": "completion_mean_projected_refusal_direction"
        if args.projected
        else "completion_mean_refusal_direction",
        "projected": bool(args.projected),
        "hidden_size": int(global_direction.shape[0]),
        "num_layers": int(directions.shape[0]),
        "selected_layers": selected,
        "layer_scores": layer_scores,
        "max_generation_tokens": args.max_generation_tokens,
        "completion_token_window": args.completion_token_window,
        "min_refusal_marker_rate": args.min_refusal_marker_rate,
        "max_benign_refusal_marker_rate": args.max_benign_refusal_marker_rate,
        "refusal_count": len(refusal_meta),
        "benign_count": len(benign_meta),
        "refusal_marker_rate": float(refusal_marker_rate),
        "benign_refusal_marker_rate": float(benign_refusal_marker_rate),
        "refusal_prompts": refusal_prompts,
        "benign_prompts": benign_prompts,
        "refusal_meta": refusal_meta,
        "benign_meta": benign_meta,
        "source_hashes": file_hashes(
            args.model,
            (
                "config.json",
                "tokenizer_config.json",
                "chat_template.jinja",
                "model.safetensors.index.json",
            ),
        ),
        "script_sha256": sha256(Path(__file__)),
        "direction_sha256": sha256(output_npz),
        "versions": package_versions(),
        "evaluation_independence_note": (
            "Direction-discovery prompts must not be reused as the only refusal "
            "promotion suite; evaluate held-out prompts separately."
        ),
        "sources": [
            "https://arxiv.org/abs/2406.11717",
            "https://github.com/NousResearch/llm-abliteration",
            "https://huggingface.co/blog/grimjim/projected-abliteration",
        ],
    }
    output_json.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"[saved] {output_npz}")
    print(f"[saved] {output_json}")
    print("[selected]", selected)


if __name__ == "__main__":
    main()
