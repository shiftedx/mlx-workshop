#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"
dmg_path="${2:-$repo_root/MLXWorkshop/build/Release/MLX-Workshop-0.1.0-beta.2-arm64.dmg}"
profile="${NOTARYTOOL_PROFILE:?set NOTARYTOOL_PROFILE to a notarytool keychain profile}"

signature="$(codesign -dvvv "$app_path" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application:"* ]] || {
  echo "FAIL: notarization requires a Developer ID Application-signed app" >&2
  exit 1
}
[[ "$signature" == *"flags="*"runtime"* ]] || {
  echo "FAIL: notarization requires hardened runtime" >&2
  exit 1
}

notary_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mlx-workshop-notary.XXXXXX")"
archive="$notary_tmp/MLX Workshop.zip"
cleanup() { rm -rf "$notary_tmp"; }
trap cleanup EXIT

ditto -c -k --keepParent "$app_path" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}" \
  "$repo_root/scripts/release/create_macos_dmg.sh" "$app_path" "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg_path"

"$repo_root/scripts/release/verify_distribution_release.sh" "$app_path" "$dmg_path"
shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
echo "$dmg_path"
