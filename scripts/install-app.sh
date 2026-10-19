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

rm -rf "$DEST/Runvoice.app"
cp -R "$REPO/dist/Runvoice.app" "$DEST/Runvoice.app"

# Приложение само регистрирует хоткеи — skhd больше не нужен.
launchctl bootout "gui/$(id -u)/com.koekeishiya.skhd" 2>/dev/null || true
pkill -x dictatehud 2>/dev/null || true

open "$DEST/Runvoice.app"

cat <<EOF
Установлено: $DEST/Runvoice.app

Дальше:
  1. Разрешите Runvoice доступ к Микрофону (запрос появится при запуске).
  2. Разрешите Accessibility: System Settings → Privacy & Security → Accessibility → Runvoice.

skhd остановлен — его хоткеи теперь не нужны.
Вернуть CLI-режим: skhd --start-service
EOF
