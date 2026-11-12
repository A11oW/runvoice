#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/live-hud-tests"
mkdir -p "$BUILD"
swiftc -module-cache-path "$REPO/.build/clang-module-cache" \
  "$REPO/app/Core/LiveTranscriber.swift" \
  "$REPO/app/Core/LivePreviewText.swift" \
  "$REPO/app/Core/RecognitionPreview.swift" \
  "$REPO/app/Core/AudioSpectrumAnalyzer.swift" \
  "$REPO/app/Core/SpeechVocabulary.swift" \
  "$REPO/app/Core/HUDDelivery.swift" \
  "$REPO/app/Core/DictationState.swift" \
  "$REPO/app/Core/DictationPasteboard.swift" \
  "$REPO/app/UI/HUDPlacement.swift" \
  "$REPO/app/UI/HUDTranscriptLayout.swift" \
  "$REPO/app/UI/HUDLayout.swift" \
  "$REPO/app/UI/WaveformView.swift" \
  "$REPO/tests/live-hud/main.swift" -o "$BUILD/tests"
"$BUILD/tests"
python3 "$REPO/tests/live-hud/pipeline.py"
