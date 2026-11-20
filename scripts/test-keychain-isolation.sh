#!/usr/bin/env bash
# test-keychain-isolation.sh — проверяет, что тестовая сборка не обращается к Keychain.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${RUNVOICE_TEST_APP:-$REPO/dist/Runvoice-test.app}"
BUILD="$REPO/.build/keychain-isolation"

[ -d "$APP" ] || {
  echo "Нет тестовой сборки: $APP" >&2
  echo "Сначала выполните: make test-app" >&2
  exit 1
}

# Статическая гарантия: каждый harness, компилирующий Keychain или все
# исходники приложения, обязан собираться с тестовым Keychain.
HARNESS_SCRIPTS=(
  "$REPO/scripts/test-native.sh"
  "$REPO/scripts/test-recognition.sh"
  "$REPO/scripts/test-pause.sh"
  "$REPO/scripts/test-api.sh"
  "$REPO/scripts/test-api-real.py"
)
for script in "${HARNESS_SCRIPTS[@]}"; do
  [ -f "$script" ] || {
    echo "Нет harness-скрипта: $script" >&2
    exit 1
  }
  if ! grep -q 'RUNVOICE_TEST_BUILD' "$script"; then
    echo "В $script нет RUNVOICE_TEST_BUILD — тест может обратиться к реальному Keychain" >&2
    exit 1
  fi
done

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$BUNDLE_ID" = "ai.opencode.runvoice.test" ] || {
  echo "Неверный bundle id тестовой сборки: $BUNDLE_ID" >&2
  exit 1
}

SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"
[ "$SIGNATURE" = "adhoc" ] || {
  echo "Тестовая сборка должна быть подписана ad-hoc, получено: ${SIGNATURE:-unknown}" >&2
  exit 1
}

check_no_security_symbols() {
  local binary="$1"
  if nm -u "$binary" | grep -Eq '_SecItem|_SecKeychain'; then
    echo "В тестовом бинарнике найдены вызовы Keychain: $binary" >&2
    nm -u "$binary" | grep -E '_SecItem|_SecKeychain' | head -20 >&2
    exit 1
  fi
}

check_no_security_symbols "$APP/Contents/MacOS/Runvoice"

MISSING_HARNESSES=()
for binary in \
  "$REPO/.build/native-tests/tests" \
  "$REPO/.build/pause-tests/tests" \
  "$REPO/.build/api-tests/tests" \
  "$REPO/.build/recognition-tests/RecognitionTests.app/Contents/MacOS/RecognitionTests"; do
  if [ -f "$binary" ]; then
    check_no_security_symbols "$binary"
  else
    MISSING_HARNESSES+=("${binary#"$REPO/"}")
  fi
done
if [ "${#MISSING_HARNESSES[@]}" -gt 0 ]; then
  echo "Не собраны harness: ${MISSING_HARNESSES[*]}; проверены только статические флаги и тестовая сборка." >&2
fi

mkdir -p "$BUILD" "$REPO/.build/clang-module-cache"
swiftc -target "$(uname -m)-apple-macos15.0" -D RUNVOICE_TEST_BUILD \
  -module-cache-path "$REPO/.build/clang-module-cache" \
  "$REPO/app/Core/Keychain.swift" "$REPO/tests/keychain/main.swift" \
  -o "$BUILD/tests"

check_no_security_symbols "$BUILD/tests"

OUTPUT="$("$BUILD/tests")"
printf '%s\n' "$OUTPUT"
case "$OUTPUT" in
  *rv-test-secret*)
    echo "Тестовое значение попало в вывод" >&2
    exit 1
    ;;
esac

echo "OK: тестовая сборка изолирована от Keychain"
