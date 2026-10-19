#!/usr/bin/env bash
# build-app.sh — собирает dist/Runvoice.app
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"
BUILD="$REPO/.build"
APP="$DIST/Runvoice.app"

# помощник вставки должен существовать
if [ ! -x "$REPO/bin/pastev" ]; then
  cc -O2 -framework ApplicationServices -o "$REPO/bin/pastev" "$REPO/bin/pastev.c"
fi

rm -rf "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> иконка"
"$REPO/scripts/make-icon.sh" "$BUILD/AppIcon.icns"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> приложение"
SWIFT_SOURCES=()
while IFS= read -r file; do SWIFT_SOURCES+=("$file"); done < <(find "$REPO/app" -name '*.swift' -print | sort)
TARGET="$(uname -m)-apple-macos13.0"
swiftc -O -target "$TARGET" -o "$APP/Contents/MacOS/Runvoice" "${SWIFT_SOURCES[@]}"

echo "==> ресурсы"
cp "$REPO/app/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/bin/dictate.sh" "$APP/Contents/Resources/dictate.sh"
cp "$REPO/bin/pastev" "$APP/Contents/Resources/pastev"
chmod +x "$APP/Contents/Resources/dictate.sh" "$APP/Contents/Resources/pastev"

echo "==> whisper"
"$REPO/scripts/bundle-whisper.sh" "$APP/Contents/Resources/whisper"

# VAD-модель маленькая (0.9 МБ), её кладём рядом с бинарниками.
VAD="${WHISPER_VAD_MODEL:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"
if [ -f "$VAD" ]; then
  mkdir -p "$APP/Contents/Resources/whisper/models"
  cp "$VAD" "$APP/Contents/Resources/whisper/models/"
else
  echo "    VAD-модель не найдена ($VAD) — распознавание будет без VAD"
fi

mkdir -p "$APP/Contents/Resources/whisper/licenses"
[ -f "$REPO/.build/whisper-src/LICENSE" ] && \
  cp "$REPO/.build/whisper-src/LICENSE" "$APP/Contents/Resources/whisper/licenses/whisper.cpp-LICENSE"
[ -f "$REPO/.build/whisper-src/ggml/LICENSE" ] && \
  cp "$REPO/.build/whisper-src/ggml/LICENSE" "$APP/Contents/Resources/whisper/licenses/ggml-LICENSE"

echo "==> подпись"
IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN_ID="$IDENTITY"
else
  SIGN_ID="-"
  echo "    ad-hoc (сертификат '$IDENTITY' не найден)"
fi

# Вложенный код подписываем до приложения.
for f in "$APP/Contents/Resources/whisper/bin/whisper-server" \
         "$APP/Contents/Resources/whisper/bin/whisper-cli" \
         "$APP/Contents/Resources/pastev"; do
  codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
done
codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 || true
echo "    $SIGN_ID"

echo "Готово: $APP"
