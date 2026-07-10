#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"
output_path="${2:-$repo_root/MLXWorkshop/build/Release/MLX-Workshop-0.1.0-beta.1-arm64.dmg}"
volume_name="MLX Workshop"

"$repo_root/scripts/release/verify_macos_app.sh" "$app_path"

staging="$(mktemp -d "${TMPDIR:-/tmp}/mlx-workshop-dmg.XXXXXX")"
mount_point="$(mktemp -d "${TMPDIR:-/tmp}/mlx-workshop-mount.XXXXXX")"
cleanup() {
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  rm -rf "$staging" "$mount_point"
}
trap cleanup EXIT

ditto "$app_path" "$staging/MLX Workshop.app"
ln -s /Applications "$staging/Applications"
rm -f "$output_path" "$output_path.sha256"
mkdir -p "$(dirname "$output_path")"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$output_path" >/dev/null

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$output_path"
fi

"$repo_root/scripts/release/verify_macos_dmg.sh" "$output_path"
shasum -a 256 "$output_path" > "$output_path.sha256"
echo "$output_path"
