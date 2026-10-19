#!/usr/bin/env bash
# make-dmg.sh — собирает установочный образ Runvoice-<version>.dmg:
# приложение + ярлык Applications + краткая инструкция.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/dist/Runvoice.app"
STAGE="$REPO/.build/dmg"

[ -d "$APP" ] || {
  echo "нет $APP — сначала соберите приложение: make app" >&2
  exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG="$REPO/dist/Runvoice-$VERSION.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Runvoice.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
Runvoice $VERSION

1. Перетащите Runvoice.app в папку Applications.
2. Запустите приложение.
3. Разрешите Accessibility и Микрофон:
   System Settings → Privacy & Security.
4. Откройте Настройки → Распознавание и скачайте модель Whisper
   (модель не входит в приложение).
5. При желании включите «Запускать при входе» в Настройки → Основные.

Модели распознавания скачиваются с Hugging Face и проверяются по SHA-256.
EOF

# Иконка тома (если доступен SetFile из Command Line Tools).
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  SetFile -a C "$STAGE" 2>/dev/null || true
fi

rm -f "$DMG" "$DMG.sha256"
echo "==> образ"
hdiutil create -volname "Runvoice $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$DMG" >/dev/null 2>&1 \
    && echo "    подпись: $IDENTITY" || echo "    ! не удалось подписать образ"
else
  echo "    образ без подписи (сертификат '$IDENTITY' не найден)"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"
rm -rf "$STAGE"

echo "Готово: $DMG"
echo "Размер: $(du -h "$DMG" | cut -f1)"
echo "SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
