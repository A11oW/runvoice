#!/usr/bin/env bash
# install.sh — сборка помощников, установка хоткеев и LaunchAgent.
# Запускать из любого места: ./install.sh
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
DICTATE="$REPO/bin/dictate.sh"

echo "==> сборка помощников"
cc -O2 -framework ApplicationServices -o "$REPO/bin/pastev" "$REPO/bin/pastev.c"
swiftc -O -o "$REPO/bin/dictatehud" "$REPO/bin/dictatehud.swift"
chmod +x "$DICTATE" "$REPO/bin/pastev" "$REPO/bin/dictatehud"

echo "==> хоткеи (~/.skhdrc)"
sed -e "s|{{DICTATE}}|$DICTATE|g" "$REPO/config/skhdrc.tmpl" > "$HOME/.skhdrc"
if command -v skhd >/dev/null 2>&1; then
  skhd --restart-service >/dev/null 2>&1 || true
  echo "    ok"
else
  echo "    ! skhd не установлен: brew install koekeishiya/formulae/skhd"
fi

echo "==> LaunchAgent whisper-server"
PLIST="$HOME/Library/LaunchAgents/ai.opencode.whisper-server.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|{{HOME}}|$HOME|g" -e "s|{{BREW}}|$BREW|g" \
  "$REPO/config/whisper-server.plist.tmpl" > "$PLIST"
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/ai.opencode.whisper-server" 2>/dev/null || true
sleep 0.5
if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
  echo "    ok"
else
  echo "    ! не удалось загрузить (проверьте, что whisper-server есть в $BREW/bin)"
fi

cat <<EOF

Готово.

Проверьте разрешения macOS (System Settings → Privacy & Security):
  • Accessibility → skhd   (хоткеи и вставка ⌘V)
  • Microphone    → skhd   (запись)

Модели Whisper должны лежать в ~/.local/share/whisper/
(см. README, раздел «Установка с нуля»).
EOF
