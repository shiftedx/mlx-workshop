#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/MLXWorkshop/build/Release/MLX Workshop.app}"

"$repo_root/scripts/release/test_package_contract.sh" "$app_path"

entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null)"
for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.files.user-selected.read-write; do
  if [[ "$entitlements" != *"<key>$entitlement</key>"* ]]; then
    echo "FAIL: signed app is missing entitlement: $entitlement" >&2
    exit 1
  fi
done

if [[ "$entitlements" == *"<key>com.apple.security.get-task-allow</key>"* ]]; then
  echo "FAIL: release app unexpectedly permits debugger attachment" >&2
  exit 1
fi

executable="$app_path/Contents/MacOS/MLX Workshop"
archs="$(lipo -archs "$executable")"
[[ " $archs " == *" arm64 "* ]] || { echo "FAIL: arm64 executable is missing" >&2; exit 1; }

size="$(du -sh "$app_path" | awk '{print $1}')"
echo "PASS: release bundle structure and entitlements verified ($size)"
