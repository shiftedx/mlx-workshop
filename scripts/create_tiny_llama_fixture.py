#!/usr/bin/env python3
"""Create a deterministic, genuinely loadable tiny float Llama source fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path

import mlx.core as mx
from mlx.utils import tree_flatten
from mlx_lm.models.llama import Model, ModelArgs
from tokenizers import Tokenizer
from tokenizers.models import WordLevel
from tokenizers.pre_tokenizers import Whitespace
from transformers import PreTrainedTokenizerFast


VOCABULARY = [
    "<unk>",
    "<s>",
    "</s>",
    "<pad>",
    "user",
    "assistant",
    "system",
    ":",
    "hello",
    "world",
    "test",
    "tiny",
    "model",
    "local",
    "mlx",
    "workshop",
    "yes",
    "no",
    "one",
    "two",
    "three",
    "four",
    "five",
    "json",
    "tool",
    "code",
    "safe",
    "parent",
    "candidate",
    "quantize",
    ".",
    "\n",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def create_fixture(output: Path, seed: int) -> dict:
    output = output.expanduser().resolve()
    if output.exists():
        raise ValueError(f"output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        config = {
            "architectures": ["LlamaForCausalLM"],
            "attention_bias": False,
            "bos_token_id": 1,
            "eos_token_id": 2,
            "hidden_size": 32,
            "initializer_range": 0.02,
            "intermediate_size": 64,
            "max_position_embeddings": 256,
            "mlp_bias": False,
            "model_type": "llama",
            "num_attention_heads": 4,
            "num_hidden_layers": 2,
            "num_key_value_heads": 2,
            "pad_token_id": 3,
            "rms_norm_eps": 1e-5,
            "rope_theta": 10000.0,
            "tie_word_embeddings": True,
            "torch_dtype": "float16",
            "transformers_version": "5.12.1",
            "use_cache": True,
            "vocab_size": len(VOCABULARY),
        }
        write_json(temporary / "config.json", config)

        mx.random.seed(seed)
        model = Model(
            ModelArgs(
                model_type="llama",
                hidden_size=config["hidden_size"],
                num_hidden_layers=config["num_hidden_layers"],
                intermediate_size=config["intermediate_size"],
                num_attention_heads=config["num_attention_heads"],
                num_key_value_heads=config["num_key_value_heads"],
                rms_norm_eps=config["rms_norm_eps"],
                vocab_size=config["vocab_size"],
                max_position_embeddings=config["max_position_embeddings"],
                attention_bias=config["attention_bias"],
                mlp_bias=config["mlp_bias"],
                rope_theta=config["rope_theta"],
                tie_word_embeddings=config["tie_word_embeddings"],
            )
        )
        weights = {
            name: value.astype(mx.float16)
            for name, value in sorted(tree_flatten(model.parameters()))
        }
        mx.eval(weights)
        shard = temporary / "model.safetensors"
        mx.save_safetensors(str(shard), weights)
        write_json(
            temporary / "model.safetensors.index.json",
            {
                "metadata": {"total_size": shard.stat().st_size},
                "weight_map": {name: shard.name for name in weights},
            },
        )

        tokenizer = Tokenizer(
            WordLevel(
                vocab={token: index for index, token in enumerate(VOCABULARY)},
                unk_token="<unk>",
            )
        )
        tokenizer.pre_tokenizer = Whitespace()
        fast_tokenizer = PreTrainedTokenizerFast(
            tokenizer_object=tokenizer,
            bos_token="<s>",
            eos_token="</s>",
            unk_token="<unk>",
            pad_token="<pad>",
            model_max_length=config["max_position_embeddings"],
        )
        fast_tokenizer.chat_template = (
            "{% for message in messages %}{{ message['role'] }}: {{ message['content'] }}\\n"
            "{% endfor %}assistant:"
        )
        fast_tokenizer.save_pretrained(temporary)

        source_files = sorted(
            path
            for path in temporary.iterdir()
            if path.is_file() and path.name != "source-manifest.json"
        )
        manifest = {
            "schema_version": 1,
            "kind": "deterministic-tiny-llama-float-source",
            "model_type": "llama",
            "seed": seed,
            "purpose": "MLX Workshop real conversion and qualification tracer bullet",
            "license": "generated-test-fixture",
            "files": [
                {
                    "path": path.name,
                    "bytes": path.stat().st_size,
                    "sha256": sha256(path),
                }
                for path in source_files
            ],
        }
        write_json(temporary / "source-manifest.json", manifest)
        os.replace(temporary, output)
        return manifest
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    manifest = create_fixture(args.output, args.seed)
    print(json.dumps(manifest, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
