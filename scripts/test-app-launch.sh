#!/usr/bin/env bash
# test-app-launch.sh — запускает тестовую сборку в режиме снимка.
# Не включает микрофон, хоткеи и Keychain; данные пишутся во временный HOME.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${RUNVOICE_TEST_APP:-$REPO/dist/Runvoice-test.app}"
BIN="$APP/Contents/MacOS/Runvoice"
SNAPSHOT="/tmp/runvoice-settings.png"

[ -x "$BIN" ] || {
  echo "Нет тестовой сборки: $APP" >&2
  echo "Сначала выполните: make test-app" >&2
  exit 1
}

mkdir -p "$REPO/.build"
TEST_HOME="$(mktemp -d "$REPO/.build/test-app-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

rm -f "$SNAPSHOT"
env CFFIXED_USER_HOME="$TEST_HOME" \
    RUNVOICE_SNAPSHOT_APPEARANCE=light \
    "$BIN" --snapshot

[ -s "$SNAPSHOT" ] || {
  echo "Снимок тестовой сборки не создан: $SNAPSHOT" >&2
  exit 1
}

echo "OK: тестовая сборка запущена, снимок: $SNAPSHOT"
