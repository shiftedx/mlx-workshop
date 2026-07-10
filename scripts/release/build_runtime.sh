#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:?usage: build_runtime.sh DESTINATION [OUTPUT_LOCK]}"
output_lock="${2:-$(dirname "$destination")/runtime.lock.json}"
uv_python_dir="$(uv python dir)"
python_home="${PYTHON_HOME:-}"
python_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["version"])' "$repo_root/runtime/runtime.lock.json")"

if [[ -z "$python_home" ]]; then
  python_home="$uv_python_dir/cpython-$python_version-macos-aarch64-none"
fi
[[ -n "$python_home" && -x "$python_home/bin/python3.11" ]] || {
  echo "FAIL: uv-managed arm64 CPython $python_version is required at $python_home" >&2
  exit 1
}
actual_python_version="$("$python_home/bin/python3.11" -c 'import platform; print(platform.python_version())')"
[[ "$actual_python_version" == "$python_version" ]] || {
  echo "FAIL: expected CPython $python_version, found $actual_python_version" >&2
  exit 1
}
expected_requirements_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["requirements_lock"]["sha256"])' "$repo_root/runtime/runtime.lock.json")"
actual_requirements_sha="$(shasum -a 256 "$repo_root/runtime/requirements.lock.txt" | awk '{print $1}')"
[[ "$actual_requirements_sha" == "$expected_requirements_sha" ]] || {
  echo "FAIL: runtime requirements lock hash does not match runtime.lock.json" >&2
  exit 1
}

rm -rf "$destination"
mkdir -p "$destination" "$(dirname "$output_lock")"
ditto "$python_home" "$destination"

uv pip install \
  --python "$destination/bin/python3.11" \
  --system \
  --break-system-packages \
  --require-hashes \
  --no-cache \
  -r "$repo_root/runtime/requirements.lock.txt"

find "$destination" -type d \( -name __pycache__ -o -name tests -o -name test \) -prune -exec rm -rf {} +
find "$destination" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

mkdir -p "$destination/scripts" "$destination/.venv/bin"
mkdir -p "$destination/licenses"
ditto "$repo_root/runtime/licenses" "$destination/licenses"
drivers=(
  inspect_mlx_model.py
  mlx_workflow_cli.py
  workflow_behavior.py
  workflow_executor.py
  workflow_host.py
  workflow_plan.py
  workflow_promotion.py
  workflow_protocol.py
  workflow_real_qualification.py
  workflow_sensitivity.py
)
for driver in "${drivers[@]}"; do
  cp "$repo_root/scripts/$driver" "$destination/scripts/$driver"
done
ln -s ../../bin/python3.11 "$destination/.venv/bin/python"

python3 "$repo_root/scripts/release/generate_runtime_manifest.py" \
  --runtime "$destination" \
  --source-lock "$repo_root/runtime/runtime.lock.json" \
  --output-lock "$output_lock"
"$repo_root/scripts/release/verify_runtime.sh" "$destination" "$output_lock"

echo "$destination"
