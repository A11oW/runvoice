#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/asr-backend-comparison/preview"
mkdir -p "$BUILD"
swiftc -O -target arm64-apple-macos15.0 -module-cache-path "$REPO/.build/clang-module-cache" \
  "$REPO/app/Core/LiveTranscriber.swift" "$REPO/app/Core/LivePreviewText.swift" \
  "$REPO/app/Core/SpeechVocabulary.swift" "$REPO/app/Core/RecognitionPreview.swift" \
  "$REPO/tests/recognition/preview-benchmark.swift" \
  -o "$BUILD/preview-benchmark"
printf '%s\n' "$BUILD/preview-benchmark"
