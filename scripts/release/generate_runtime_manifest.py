#!/usr/bin/env python3
"""Generate the bundled runtime's integrity manifest and resolved lock."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source-lock", type=Path, required=True)
    parser.add_argument("--output-lock", type=Path, required=True)
    args = parser.parse_args()

    root = args.runtime.resolve()
    entries = {
        path.relative_to(root).as_posix(): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file() and path.name != "runtime-manifest.json"
    }
    manifest = {
        "schema_version": 1,
        "algorithm": "sha256",
        "file_count": len(entries),
        "files": entries,
    }
    manifest_path = root / "runtime-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    lock = json.loads(args.source_lock.read_text())
    lock["status"] = "bundled-and-verified"
    lock["manifest"] = {
        "path": "Runtime/runtime-manifest.json",
        "sha256": sha256(manifest_path),
        "file_count": len(entries),
    }
    lock["driver_files"] = {
        name: digest
        for name, digest in entries.items()
        if name.startswith("scripts/")
    }
    critical_names = {
        "bin/python3.11",
        "lib/libpython3.11.dylib",
        "lib/python3.11/site-packages/mlx/core.cpython-311-darwin.so",
        "lib/python3.11/site-packages/mlx/lib/libmlx.dylib",
        "lib/python3.11/site-packages/mlx/lib/mlx.metallib",
        "lib/python3.11/site-packages/mlx_lm/__init__.py",
        "lib/python3.11/site-packages/transformers/__init__.py",
    }
    lock["critical_files"] = {
        name: digest
        for name, digest in entries.items()
        if name.startswith("scripts/") or name in critical_names
    }
    args.output_lock.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
