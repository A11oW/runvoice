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

СПОСОБ 1 — проще
  Правый клик по «Установить Runvoice.command» → «Открыть».
  Скрипт скопирует приложение в Applications, снимет карантин и запустит его.
  Если macOS не даёт открыть скрипт: Terminal →
    bash "/Volumes/Runvoice $VERSION/Установить Runvoice.command"

СПОСОБ 2 — вручную
  1. Перетащите Runvoice.app в папку Applications.
  2. Правый клик по приложению → «Открыть» (или System Settings →
     Privacy & Security → «Открыть всё равно»).
  3. Если macOS пишет «Не удалось открыть программу», выполните в Terminal:
       xattr -dr com.apple.quarantine /Applications/Runvoice.app

ПОСЛЕ ЗАПУСКА
  • Разрешите Accessibility и Микрофон:
    System Settings → Privacy & Security.
  • Настройки → Распознавание → скачайте модель Whisper
    (модель не входит в приложение).
  • При желании включите «Запускать при входе» в Настройки → Основные.

Почему так: приложение подписано локальным сертификатом, а не Developer ID
Apple, поэтому Gatekeeper на другом Mac требует подтверждения.
EOF

cat > "$STAGE/Установить Runvoice.command" <<'INSTALL'
#!/bin/bash
set -euo pipefail

SRC="$(cd -- "$(dirname -- "$0")" && pwd)/Runvoice.app"
DEST="${RUNVOICE_DEST:-/Applications/Runvoice.app}"

if [ ! -d "$SRC" ]; then
  echo "Runvoice.app не найден рядом со скриптом."
  read -r -p "Нажмите Enter, чтобы закрыть…" _
  exit 1
fi

DEST_DIR="$(dirname "$DEST")"
if ! mkdir -p "$DEST_DIR" 2>/dev/null || [ ! -w "$DEST_DIR" ]; then
  DEST="$HOME/Applications/Runvoice.app"
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi

pkill -x Runvoice 2>/dev/null || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Старый CLI-режим больше не нужен приложению.
launchctl bootout "gui/$(id -u)/ai.opencode.whisper-server" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/ai.opencode.whisper-server.plist"

open "$DEST"

cat <<EOF
Runvoice установлен: $DEST

Дальше:
  1. Разрешите Accessibility и Микрофон в System Settings → Privacy & Security.
  2. Настройки → Распознавание → скачайте модель Whisper.
  3. При желании включите «Запускать при входе» в Настройки → Основные.
EOF

read -r -p "Нажмите Enter, чтобы закрыть…" _
INSTALL
chmod +x "$STAGE/Установить Runvoice.command"

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
