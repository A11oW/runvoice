#!/usr/bin/env bash
# build-app.sh — собирает две версии приложения:
#   dist/Runvoice-arm64.app  (Apple Silicon, Whisper с Metal)
#   dist/Runvoice-intel.app  (Intel, Whisper на CPU)
# и копию для текущей машины: dist/Runvoice.app
#
# build-app.sh test — тестовая сборка dist/Runvoice-test.app:
#   отдельный bundle id, ad-hoc-подпись, Keychain в памяти и каталог Runvoice-Test.
#   Сертификат подписи не используется и не запрашивается.
set -euo pipefail

MODE="${1:-final}"
case "$MODE" in
  final|test) ;;
  *)
    echo "Неизвестный режим сборки: $MODE (ожидается final или test)" >&2
    exit 2
    ;;
esac

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"
BUILD="$REPO/.build"

if [ "$MODE" = "test" ]; then
  TEST_ARCH="${RUNVOICE_TEST_ARCH:-$(uname -m)}"
  case "$TEST_ARCH" in
    arm64|x86_64) ;;
    *)
      echo "Неизвестная архитектура тестовой сборки: $TEST_ARCH" >&2
      exit 2
      ;;
  esac
fi

bash "$REPO/scripts/prepare-sparkle.sh"

# помощник вставки для CLI должен существовать
if [ ! -x "$REPO/bin/pastev" ]; then
  cc -O2 -mmacosx-version-min=15.0 -framework ApplicationServices -o "$REPO/bin/pastev" "$REPO/bin/pastev.c"
fi

mkdir -p "$DIST" "$BUILD"

ASR=""
if [ "$MODE" = "final" ] || [ "$TEST_ARCH" = "arm64" ]; then
  echo "==> потоковый ASR (Apple Silicon)"
  swift build --package-path "$REPO/streaming" --scratch-path "$BUILD/streaming" \
    -c release --product RunvoiceASR --arch arm64
  ASR="$BUILD/streaming/arm64-apple-macosx/release/RunvoiceASR"
fi

echo "==> иконка"
"$REPO/scripts/make-icon.sh" "$BUILD/AppIcon.icns"

SWIFT_SOURCES=()
while IFS= read -r file; do SWIFT_SOURCES+=("$file"); done < <(find "$REPO/app" -name '*.swift' -print | sort)

VAD="${WHISPER_VAD_MODEL:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"

if [ "$MODE" = "test" ]; then
  SIGN_ID="-"
else
  IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
  if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN_ID="$IDENTITY"
  else
    SIGN_ID="-"
    echo "    ad-hoc (сертификат '$IDENTITY' не найден)"
  fi
fi

build_variant() {
  local arch="$1"
  local label="$2"
  local title="$3"
  local app="$DIST/Runvoice-$label.app"

  echo "==> $title"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  cp "$BUILD/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  if [ "$MODE" = "test" ]; then
    swiftc -O -target "$arch-apple-macos15.0" \
      -F "$BUILD/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
      -D RUNVOICE_TEST_BUILD \
      -o "$app/Contents/MacOS/Runvoice" "${SWIFT_SOURCES[@]}"
  else
    swiftc -O -target "$arch-apple-macos15.0" \
      -F "$BUILD/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
      -o "$app/Contents/MacOS/Runvoice" "${SWIFT_SOURCES[@]}"
  fi

  cp "$REPO/app/Info.plist" "$app/Contents/Info.plist"
  if [ "$MODE" = "test" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.opencode.runvoice.test" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Runvoice Test" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Runvoice Test" "$app/Contents/Info.plist"
  fi
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://github.com/A11oW/runvoice/releases/latest/download/appcast-$label.xml" "$app/Contents/Info.plist"
  mkdir -p "$app/Contents/Frameworks"
  ditto "$BUILD/sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
  cp "$BUILD/sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
  cp "$REPO/bin/dictate.sh" "$app/Contents/Resources/dictate.sh"
  cp "$REPO/resources/warmup.wav" "$app/Contents/Resources/warmup.wav"
  if [ "$arch" = "arm64" ]; then
    cp "$ASR" "$app/Contents/Resources/RunvoiceASR"
    codesign --force --sign "$SIGN_ID" "$app/Contents/Resources/RunvoiceASR" >/dev/null
    mkdir -p "$app/Contents/Resources/licenses"
    cp -f "$BUILD/streaming/checkouts/FluidAudio/LICENSE" "$app/Contents/Resources/licenses/FluidAudio-LICENSE"
    cp "$REPO/resources/Parakeet-NOTICE.txt" "$app/Contents/Resources/licenses/Parakeet-NOTICE.txt"
    cp -f "$BUILD/streaming/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md" \
      "$app/Contents/Resources/licenses/fastcluster-LICENSE.md"
  fi

  if ! cc -O2 -arch "$arch" -mmacosx-version-min=15.0 -framework ApplicationServices \
        -o "$app/Contents/Resources/pastev" "$REPO/bin/pastev.c" 2>/dev/null; then
    cp "$REPO/bin/pastev" "$app/Contents/Resources/pastev"
  fi
  chmod +x "$app/Contents/Resources/dictate.sh" "$app/Contents/Resources/pastev"

  "$REPO/scripts/bundle-whisper.sh" "$app/Contents/Resources/whisper" "$arch"

  bash "$REPO/scripts/build-vad.sh" "$app/Contents/Resources/whisper/bin/runvoice-vad" "$arch"

  if [ -f "$VAD" ]; then
    mkdir -p "$app/Contents/Resources/whisper/models"
    cp "$VAD" "$app/Contents/Resources/whisper/models/"
  else
    echo "    VAD-модель не найдена ($VAD)" >&2; exit 1
  fi

  mkdir -p "$app/Contents/Resources/whisper/licenses"
  cp "$REPO/resources/Whisper-CodeSwitch-NOTICE.txt" "$app/Contents/Resources/whisper/licenses/Whisper-CodeSwitch-NOTICE.txt"
  [ -f "$BUILD/whisper-src/LICENSE" ] && \
    cp "$BUILD/whisper-src/LICENSE" "$app/Contents/Resources/whisper/licenses/whisper.cpp-LICENSE"

  for f in "$app/Contents/Resources/whisper/bin/runvoice-vad" \
           "$app/Contents/Resources/whisper/bin/whisper-server" \
           "$app/Contents/Resources/whisper/bin/whisper-cli" \
           "$app/Contents/Resources/pastev"; do
    codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
  done
  codesign --force --deep --sign "$SIGN_ID" "$app" >/dev/null 2>&1 || true
  echo "    $app ($(lipo -info "$app/Contents/MacOS/Runvoice" | sed 's/.*: //'))"
}

if [ "$MODE" = "test" ]; then
  build_variant "$TEST_ARCH" test "Test ($TEST_ARCH)"
  echo "==> тестовая сборка: $DIST/Runvoice-test.app ($TEST_ARCH)"
  echo "Готово."
  exit 0
fi

build_variant arm64 arm64 "Apple Silicon (arm64)"
build_variant x86_64 intel "Intel (x86_64)"

HOST="$(uname -m)"
case "$HOST" in
  x86_64) HOST_LABEL=intel ;;
  *) HOST_LABEL=arm64 ;;
esac
rm -rf "$DIST/Runvoice.app"
ditto "$DIST/Runvoice-$HOST_LABEL.app" "$DIST/Runvoice.app"
echo "==> для этой машины: dist/Runvoice.app ($HOST_LABEL)"
echo "Готово."
