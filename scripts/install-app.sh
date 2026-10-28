#!/usr/bin/env bash
# install-app.sh — собирает и устанавливает Runvoice.app, отключает skhd.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$REPO/scripts/build-app.sh"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

# Старый процесс нужно остановить до замены .app: иначе он продолжит
# работать со старым кодом/окнами HUD до следующего входа.
pkill -x Runvoice 2>/dev/null || true
sleep 0.3

rm -rf "$DEST/Runvoice.app"
cp -R "$REPO/dist/Runvoice.app" "$DEST/Runvoice.app"

# Приложение само регистрирует хоткеи — skhd больше не нужен.
launchctl bootout "gui/$(id -u)/com.koekeishiya.skhd" 2>/dev/null || true
pkill -x dictatehud 2>/dev/null || true

# Whisper теперь встроен в приложение, старый LaunchAgent больше не нужен.
launchctl bootout "gui/$(id -u)/ai.opencode.whisper-server" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/ai.opencode.whisper-server.plist"

open "$DEST/Runvoice.app"

cat <<EOF
Установлено: $DEST/Runvoice.app

Дальше:
  1. Разрешите Runvoice доступ к Микрофону (запрос появится при запуске).
  2. Разрешите Accessibility: System Settings → Privacy & Security → Accessibility → Runvoice.
  3. Откройте «Настройки» → «Модели» и скачайте модель (или выберите уже скачанную).

skhd остановлен — его хоткеи теперь не нужны.
Старый LaunchAgent whisper-server удалён: приложение запускает сервер само.
Вернуть CLI-режим: ./install.sh && skhd --start-service
EOF
