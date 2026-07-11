#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"

if [[ ! -d "$app_path" ]]; then
  echo "FAIL: app bundle does not exist: $app_path" >&2
  exit 1
fi

info="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/MLX Workshop"
privacy="$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
runtime_lock="$app_path/Contents/Resources/runtime.lock.json"
privacy_policy="$app_path/Contents/Resources/PRIVACY.md"
third_party_notices="$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
project_license="$app_path/Contents/Resources/LICENSE"
runtime_root="$app_path/Contents/Resources/Runtime"
runtime_manifest="$runtime_root/runtime-manifest.json"

for required in \
  "$info" \
  "$executable" \
  "$privacy" \
  "$privacy_policy" \
  "$third_party_notices" \
  "$project_license" \
  "$runtime_lock" \
  "$runtime_manifest" \
  "$runtime_root/bin/python3" \
  "$runtime_root/.venv/bin/python" \
  "$runtime_root/scripts/mlx_workflow_cli.py"; do
  if [[ ! -e "$required" ]]; then
    echo "FAIL: missing bundle artifact: $required" >&2
    exit 1
  fi
done

[[ -f "$runtime_root/licenses/CPython-3.11.14-LICENSE.txt" ]] || {
  echo "FAIL: bundled runtime is missing the CPython license" >&2
  exit 1
}

[[ -x "$executable" ]] || { echo "FAIL: app executable is not executable" >&2; exit 1; }

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")"

[[ "$bundle_id" == "com.cozylabs.MLXWorkshop" ]] || { echo "FAIL: unexpected bundle id: $bundle_id" >&2; exit 1; }
[[ "$short_version" == "0.1.0-beta.2" ]] || { echo "FAIL: unexpected version: $short_version" >&2; exit 1; }
[[ "$build_version" == "2" ]] || { echo "FAIL: unexpected build: $build_version" >&2; exit 1; }
[[ "$minimum_os" == "14.0" ]] || { echo "FAIL: unexpected minimum macOS: $minimum_os" >&2; exit 1; }

plutil -lint "$info" "$privacy" >/dev/null
python3 -m json.tool "$runtime_lock" >/dev/null
python3 -m json.tool "$runtime_manifest" >/dev/null
runtime_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$runtime_lock")"
[[ "$runtime_status" == "bundled-and-verified" ]] || {
  echo "FAIL: bundled runtime is not release-ready: $runtime_status" >&2
  exit 1
}
"$repo_root/scripts/release/verify_runtime.sh" "$runtime_root" "$runtime_lock"
codesign --verify --deep --strict "$app_path"

signature="$(codesign -dv "$app_path" 2>&1)"
if [[ "$signature" == *"Signature=adhoc"* ]]; then
  signature_kind="ad-hoc"
elif [[ "$signature" == *"Authority=Developer ID Application:"* ]]; then
  signature_kind="Developer ID Application"
else
  echo "FAIL: app has neither an ad-hoc nor Developer ID Application signature" >&2
  exit 1
fi

echo "PASS: verified MLX Workshop bundle contract"
echo "  bundle: $app_path"
echo "  identifier: $bundle_id"
echo "  version: $short_version ($build_version)"
echo "  minimum macOS: $minimum_os"
echo "  signature: $signature_kind"
