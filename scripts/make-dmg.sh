#!/usr/bin/env bash
# make-dmg.sh — собирает два установочных образа:
#   Runvoice-<version>-arm64.dmg  (Apple Silicon)
#   Runvoice-<version>-intel.dmg  (Intel)
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"
BUILD="$REPO/.build"

IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"

write_install_command() {
  local stage="$1"
  local version="$2"
  cat > "$stage/Установить Runvoice.command" <<'INSTALL'
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
  4. Настройки → Провайдеры → добавьте AI-провайдера и выберите его
     в «Постобработке» для диктовки и улучшения.
  5. Выделите текст в любом редакторе и нажмите ⌥⌘E для улучшения.
EOF

read -r -p "Нажмите Enter, чтобы закрыть…" _
INSTALL
  chmod +x "$stage/Установить Runvoice.command"
}

make_one() {
  local label="$1"
  local arch_title="$2"
  local app="$DIST/Runvoice-$label.app"

  [ -d "$app" ] || {
    echo "нет $app — сначала соберите приложение: make app" >&2
    exit 1
  }

  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo 1.0)"
  local stage="$BUILD/dmg-$label"
  local dmg="$DIST/Runvoice-$version-$label.dmg"

  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$app" "$stage/Runvoice.app"
  ln -s /Applications "$stage/Applications"

  cat > "$stage/README.txt" <<EOF
Runvoice $version
Версия для $arch_title, macOS 13+.

СПОСОБ 1 — проще
  Правый клик по «Установить Runvoice.command» → «Открыть».
  Скрипт скопирует приложение в Applications, снимет карантин и запустит его.
  Если macOS не даёт открыть скрипт: Terminal →
    bash "/Volumes/Runvoice $version $label/Установить Runvoice.command"

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
  • Настройки → Провайдеры → добавьте AI-провайдера и выберите его
    в «Постобработке» для диктовки и улучшения.
  • Выделите текст в редакторе и нажмите ⌥⌘E — модель улучшит его.
  • При желании включите «Запускать при входе» в Настройки → Основные.

Почему так: приложение подписано локальным сертификатом, а не Developer ID
Apple, поэтому Gatekeeper на другом Mac требует подтверждения.
EOF

  write_install_command "$stage" "$version"

  if [ -f "$app/Contents/Resources/AppIcon.icns" ]; then
    cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
    SetFile -a C "$stage" 2>/dev/null || true
  fi

  rm -f "$dmg" "$dmg.sha256"
  echo "==> $label"
  hdiutil create -volname "Runvoice $version $label" -srcfolder "$stage" \
    -ov -format UDZO -fs HFS+ "$dmg" >/dev/null
  hdiutil verify "$dmg" >/dev/null

  if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$dmg" >/dev/null 2>&1 \
      && echo "    подпись: $IDENTITY" || echo "    ! не удалось подписать образ"
  else
    echo "    образ без подписи (сертификат '$IDENTITY' не найден)"
  fi

  ( cd "$DIST" && shasum -a 256 "$(basename "$dmg")" ) > "$dmg.sha256"
  rm -rf "$stage"

  echo "Готово: $dmg"
  echo "Размер: $(du -h "$dmg" | cut -f1)"
  echo "SHA-256: $(cut -d' ' -f1 "$dmg.sha256")"
}

# Старый универсальный образ больше не нужен.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIST/Runvoice.app/Contents/Info.plist" 2>/dev/null || echo 1.0)"
rm -f "$DIST/Runvoice-$VERSION.dmg" "$DIST/Runvoice-$VERSION.dmg.sha256"

make_one arm64 "Apple Silicon (arm64)"
make_one intel "Intel (x86_64)"
