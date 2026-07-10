#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"

"$repo_root/scripts/release/verify_macos_app.sh" "$app_path"

runtime_lock="$app_path/Contents/Resources/runtime.lock.json"
runtime_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$runtime_lock")"
if [[ "$runtime_status" != "bundled-and-verified" ]]; then
  echo "BLOCKED: public release requires a bundled, integrity-verified runtime; lock status is '$runtime_status'." >&2
  exit 1
fi

runtime_root="$app_path/Contents/Resources/Runtime"
for required in "$runtime_root/bin/python3" "$runtime_root/scripts/mlx_workflow_cli.py"; do
  if [[ ! -e "$required" ]]; then
    echo "BLOCKED: public release runtime is missing $required" >&2
    exit 1
  fi
done

"$repo_root/scripts/release/verify_runtime.sh" "$runtime_root" "$runtime_lock"

echo "PASS: public-release runtime gate"
