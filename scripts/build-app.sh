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
swiftc -O -o "$APP/Contents/MacOS/Runvoice" "$REPO/app/Runvoice.swift"

echo "==> ресурсы"
cp "$REPO/app/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/bin/dictate.sh" "$APP/Contents/Resources/dictate.sh"
cp "$REPO/bin/pastev" "$APP/Contents/Resources/pastev"
chmod +x "$APP/Contents/Resources/dictate.sh" "$APP/Contents/Resources/pastev"

echo "==> подпись"
IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "    $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "    ad-hoc (сертификат '$IDENTITY' не найден)"
fi

echo "Готово: $APP"
