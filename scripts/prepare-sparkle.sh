#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$REPO/.build/sparkle"
SHA=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
mkdir -p "$CACHE"
if [ ! -f "$CACHE/distribution.tar.xz" ]; then
 curl -fL --retry 2 https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$CACHE/distribution.tar.xz"
fi
[ "$(shasum -a 256 "$CACHE/distribution.tar.xz" | cut -d ' ' -f 1)" = "$SHA" ] || { echo 'Неверная SHA-256 Sparkle' >&2; exit 1; }
if [ ! -d "$CACHE/Sparkle.framework" ]; then tar -xf "$CACHE/distribution.tar.xz" -C "$CACHE"; fi
