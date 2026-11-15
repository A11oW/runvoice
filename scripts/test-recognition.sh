#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/recognition-tests"
APP="$BUILD/RecognitionTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.opencode.runvoice.recognition-tests</string>
<key>CFBundleName</key><string>Runvoice Recognition Tests</string>
<key>CFBundleExecutable</key><string>RecognitionTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$REPO/app" -name '*.swift' ! -name main.swift ! -name AppDelegate.swift -print | sort
)
swiftc -target "$(uname -m)-apple-macos15.0" -module-cache-path "$REPO/.build/clang-module-cache" \
  "${SOURCES[@]}" "$REPO/tests/recognition/main.swift" -o "$APP/Contents/MacOS/RecognitionTests"
runvoice_test_home=$(mktemp -d "$BUILD/home.XXXXXX")
trap 'rm -rf "$runvoice_test_home"' EXIT
env CFFIXED_USER_HOME="$runvoice_test_home" "$APP/Contents/MacOS/RecognitionTests"
