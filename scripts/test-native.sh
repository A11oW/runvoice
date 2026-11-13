#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/native-tests"
mkdir -p "$BUILD"
swiftc -target "$(uname -m)-apple-macos15.0" -module-cache-path "$REPO/.build/clang-module-cache" \
  "$REPO/app/Core/LiveTranscriber.swift" "$REPO/app/Core/SpeechVocabulary.swift" \
  "$REPO/app/Core/LivePreviewText.swift" \
  "$REPO/app/Core/RecognitionPreview.swift" \
  "$REPO/app/Core/DictationKeyPolicy.swift" "$REPO/app/App/HotkeyMonitor.swift" \
  "$REPO/app/Core/AudioSpectrumAnalyzer.swift" \
  "$REPO/app/Core/Settings.swift" "$REPO/app/Core/Paths.swift" "$REPO/app/Core/Keychain.swift" \
  "$REPO/app/Core/Log.swift" \
  "$REPO/app/Core/FluidSpeechClient.swift" \
  "$REPO/app/Core/AudioInputDevice.swift" \
  "$REPO/app/App/HALInput.swift" \
  "$REPO/app/App/NativeAudioRecorder.swift" "$REPO/tests/native/enter.swift" \
  "$REPO/tests/native/main.swift" -o "$BUILD/tests"
"$BUILD/tests"
