#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/editing-tests"
APP="$BUILD/EditingTests.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.opencode.runvoice.editing-tests</string>
<key>CFBundleName</key><string>Runvoice Editing Tests</string>
<key>CFBundleExecutable</key><string>EditingTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><false/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
swiftc -target "$(uname -m)-apple-macos15.0" -module-cache-path "$REPO/.build/clang-module-cache" \
  "$REPO/app/App/TextEditingCommands.swift" "$REPO/app/Core/RecognitionPreview.swift" \
  "$REPO/app/UI/RecognitionPreviewControls.swift" "$REPO/app/UI/HUDSpinnerView.swift" \
  "$REPO/app/Core/SpeechVocabulary.swift" "$REPO/app/UI/SpeechVocabularyEditor.swift" \
  "$REPO/app/UI/StatusHintController.swift" \
  "$REPO/tests/editing/main.swift" -o "$APP/Contents/MacOS/EditingTests"
codesign --force --sign - "$APP" >/dev/null
# LaunchServices передаёт фокус тестовому окну; прямой запуск CLI этого не делает.
: > "$BUILD/stdout.log"
: > "$BUILD/stderr.log"
open -n -W --stdout "$BUILD/stdout.log" --stderr "$BUILD/stderr.log" "$APP"
cat "$BUILD/stdout.log" "$BUILD/stderr.log"
rg -q '^OK: ' "$BUILD/stdout.log"
