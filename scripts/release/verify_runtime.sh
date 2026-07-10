#!/bin/bash
set -euo pipefail

runtime_root="${1:?usage: verify_runtime.sh RUNTIME_ROOT RUNTIME_LOCK}"
runtime_lock="${2:?usage: verify_runtime.sh RUNTIME_ROOT RUNTIME_LOCK}"
manifest="$runtime_root/runtime-manifest.json"

python3 - "$runtime_root" "$runtime_lock" "$manifest" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lock = json.load(open(sys.argv[2]))
manifest_path = pathlib.Path(sys.argv[3])
manifest = json.load(open(manifest_path))

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if lock.get("status") != "bundled-and-verified":
    raise SystemExit("runtime lock is not bundled-and-verified")
if sha256(manifest_path) != lock["manifest"]["sha256"]:
    raise SystemExit("runtime manifest hash mismatch")
files = manifest.get("files", {})
if manifest.get("file_count") != len(files):
    raise SystemExit("runtime manifest file count mismatch")
for relative, expected in files.items():
    path = (root / relative).resolve()
    if root not in path.parents:
        raise SystemExit(f"unsafe manifest path: {relative}")
    if not path.is_file() or sha256(path) != expected:
        raise SystemExit(f"runtime file hash mismatch: {relative}")
actual = {
    path.relative_to(root).as_posix()
    for path in root.rglob("*")
    if path.is_file() and path.name != "runtime-manifest.json"
}
if actual != set(files):
    missing = sorted(set(files) - actual)
    extra = sorted(actual - set(files))
    raise SystemExit(f"runtime file set mismatch; missing={missing}, extra={extra}")
PY

PYTHONDONTWRITEBYTECODE=1 "$runtime_root/.venv/bin/python" -c \
  'import mlx, mlx_lm, safetensors, tokenizers, transformers; print("runtime imports: ok")' >/dev/null
smoke_workspace="$(mktemp -d "${TMPDIR:-/tmp}/mlx-workshop-runtime-smoke.XXXXXX")"
trap 'rm -rf "$smoke_workspace"' EXIT
PYTHONDONTWRITEBYTECODE=1 "$runtime_root/.venv/bin/python" "$runtime_root/scripts/mlx_workflow_cli.py" \
  --machine host --workspace "$smoke_workspace" \
  --run-id runtime-smoke >/dev/null

echo "PASS: bundled runtime integrity and smoke tests"
