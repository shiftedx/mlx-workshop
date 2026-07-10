#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"
dmg_path="${2:-$repo_root/MLXWorkshop/build/Release/MLX-Workshop-0.1.0-beta.1-arm64.dmg}"

"$repo_root/scripts/release/verify_public_release.sh" "$app_path"
"$repo_root/scripts/release/verify_macos_dmg.sh" "$dmg_path"

signature="$(codesign -dvvv "$app_path" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
  echo "BLOCKED: friend-installable distribution requires a Developer ID Application signature." >&2
  exit 1
fi
if [[ "$signature" != *"flags="*"runtime"* ]]; then
  echo "BLOCKED: distribution signature is missing hardened runtime." >&2
  exit 1
fi
if [[ "$signature" != *"Timestamp="* ]]; then
  echo "BLOCKED: distribution signature is missing a secure timestamp." >&2
  exit 1
fi

spctl --assess --type execute --verbose=4 "$app_path"
xcrun stapler validate "$app_path"
xcrun stapler validate "$dmg_path"

echo "PASS: Developer ID, Gatekeeper, notarization, and stapling distribution gate"
