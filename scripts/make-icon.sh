#!/usr/bin/env bash
# make-icon.sh <output.icns> — генерирует иконку приложения.
set -euo pipefail

OUT="${1:?usage: make-icon.sh <output.icns>}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O -o "$TMP/genicon" "$HERE/genicon.swift"
"$TMP/genicon" "$TMP/icon.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
