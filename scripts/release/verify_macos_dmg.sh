#!/bin/bash
set -euo pipefail

dmg_path="${1:?usage: verify_macos_dmg.sh DMG_PATH}"
[[ -f "$dmg_path" ]] || { echo "FAIL: DMG does not exist: $dmg_path" >&2; exit 1; }

mount_point="$(mktemp -d "${TMPDIR:-/tmp}/mlx-workshop-verify-dmg.XXXXXX")"
cleanup() {
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  rm -rf "$mount_point"
}
trap cleanup EXIT

hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_point" -quiet
[[ -d "$mount_point/MLX Workshop.app" ]] || {
  echo "FAIL: mounted DMG is missing MLX Workshop.app" >&2
  exit 1
}
[[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == "/Applications" ]] || {
  echo "FAIL: mounted DMG is missing the Applications install link" >&2
  exit 1
}
codesign --verify --deep --strict "$mount_point/MLX Workshop.app"
hdiutil verify "$dmg_path" >/dev/null

echo "PASS: verified installable DMG structure and embedded app signature"
