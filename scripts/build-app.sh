#!/usr/bin/env bash
# build-app.sh — собирает две версии приложения:
#   dist/Runvoice-arm64.app  (Apple Silicon, Whisper с Metal)
#   dist/Runvoice-intel.app  (Intel, Whisper на CPU)
# и копию для текущей машины: dist/Runvoice.app
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"
BUILD="$REPO/.build"

# помощник вставки для CLI должен существовать
if [ ! -x "$REPO/bin/pastev" ]; then
  cc -O2 -framework ApplicationServices -o "$REPO/bin/pastev" "$REPO/bin/pastev.c"
fi

mkdir -p "$DIST" "$BUILD"

echo "==> потоковый ASR (Apple Silicon)"
swift build --package-path "$REPO/streaming" --scratch-path "$BUILD/streaming" \
  -c release --product RunvoiceASR --arch arm64
ASR="$BUILD/streaming/arm64-apple-macosx/release/RunvoiceASR"

echo "==> иконка"
"$REPO/scripts/make-icon.sh" "$BUILD/AppIcon.icns"

SWIFT_SOURCES=()
while IFS= read -r file; do SWIFT_SOURCES+=("$file"); done < <(find "$REPO/app" -name '*.swift' -print | sort)

VAD="${WHISPER_VAD_MODEL:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"

IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN_ID="$IDENTITY"
else
  SIGN_ID="-"
  echo "    ad-hoc (сертификат '$IDENTITY' не найден)"
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
  swiftc -O -target "$arch-apple-macos15.0" \
    -o "$app/Contents/MacOS/Runvoice" "${SWIFT_SOURCES[@]}"

  cp "$REPO/app/Info.plist" "$app/Contents/Info.plist"
  cp "$REPO/bin/dictate.sh" "$app/Contents/Resources/dictate.sh"
  cp "$REPO/resources/warmup.wav" "$app/Contents/Resources/warmup.wav"
  if [ "$arch" = "arm64" ]; then
    cp "$ASR" "$app/Contents/Resources/RunvoiceASR"
    codesign --force --sign "$SIGN_ID" "$app/Contents/Resources/RunvoiceASR" >/dev/null
    mkdir -p "$app/Contents/Resources/licenses"
    cp "$BUILD/streaming/checkouts/FluidAudio/LICENSE" "$app/Contents/Resources/licenses/FluidAudio-LICENSE"
    cp "$BUILD/streaming/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md" \
      "$app/Contents/Resources/licenses/fastcluster-LICENSE.md"
  fi

  if ! cc -O2 -arch "$arch" -framework ApplicationServices \
        -o "$app/Contents/Resources/pastev" "$REPO/bin/pastev.c" 2>/dev/null; then
    cp "$REPO/bin/pastev" "$app/Contents/Resources/pastev"
  fi
  chmod +x "$app/Contents/Resources/dictate.sh" "$app/Contents/Resources/pastev"

  "$REPO/scripts/bundle-whisper.sh" "$app/Contents/Resources/whisper" "$arch"

  if [ -f "$VAD" ]; then
    mkdir -p "$app/Contents/Resources/whisper/models"
    cp "$VAD" "$app/Contents/Resources/whisper/models/"
  else
    echo "    VAD-модель не найдена ($VAD) — распознавание будет без VAD"
  fi

  mkdir -p "$app/Contents/Resources/whisper/licenses"
  [ -f "$BUILD/whisper-src/LICENSE" ] && \
    cp "$BUILD/whisper-src/LICENSE" "$app/Contents/Resources/whisper/licenses/whisper.cpp-LICENSE"

  for f in "$app/Contents/Resources/whisper/bin/whisper-server" \
           "$app/Contents/Resources/whisper/bin/whisper-cli" \
           "$app/Contents/Resources/pastev"; do
    codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
  done
  codesign --force --deep --sign "$SIGN_ID" "$app" >/dev/null 2>&1 || true
  echo "    $app ($(lipo -info "$app/Contents/MacOS/Runvoice" | sed 's/.*: //'))"
}

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
