#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
project_root="$repo_root/MLXWorkshop"
configuration="${CONFIGURATION:-Release}"

command -v xcodegen >/dev/null || {
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
}

for plist in \
  "$project_root/Resources/Info.plist" \
  "$project_root/Resources/PrivacyInfo.xcprivacy" \
  "$project_root/Resources/MLXWorkshop.entitlements"; do
  plutil -lint "$plist" >/dev/null
done
python3 -m json.tool "$repo_root/runtime/runtime.lock.json" >/dev/null

(
  cd "$project_root"
  xcodegen generate --spec Project.yml
  xcodebuild \
    -project MLXWorkshop.xcodeproj \
    -scheme "MLX Workshop" \
    -configuration "$configuration" \
    -derivedDataPath build/DerivedData \
    SYMROOT="$project_root/build" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    MLX_BUNDLE_RUNTIME=1 \
    build
)

app_path="$project_root/build/$configuration/MLX Workshop.app"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$project_root/Resources/MLXWorkshop.entitlements" \
    "$app_path"
else
  codesign --force --deep --sign - \
    --timestamp=none \
    --entitlements "$project_root/Resources/MLXWorkshop.entitlements" \
    "$app_path"
fi
"$repo_root/scripts/release/verify_macos_app.sh" "$app_path"
echo "$app_path"
