#!/usr/bin/env bash
# sign-release.sh — подписывает приложения выпуска сертификатом Runvoice Local Signing,
# проверяет certificate leaf и пересоздаёт DMG. Ad-hoc подпись выпуска не допускается.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"
IDENTITY="${RUNVOICE_SIGN_IDENTITY:-Runvoice Local Signing}"
# SHA-1 сертификата Runvoice Local Signing; публичный отпечаток, не секрет.
EXPECTED_LEAF="4ffe265ebd1f1e1d196faefb795df66c8c17585c"

fail() {
  echo "sign-release: $*" >&2
  exit 1
}

matches="$(security find-identity -p codesigning | grep -c "\"$IDENTITY\"" || true)"
[ "$matches" = "1" ] || fail "нужна ровно одна identity «${IDENTITY}», найдено: $matches"

sign_binary() {
  local path="$1"
  [ -e "$path" ] || return 0
  codesign --force --sign "$IDENTITY" "$path" >/dev/null
}

check_app() {
  local app="$1"
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 || fail "подпись не проходит проверку: $app"
  codesign -d -r- "$app" 2>&1 | grep -q "certificate leaf = H\"$EXPECTED_LEAF\"" \
    || fail "certificate leaf не совпадает с $EXPECTED_LEAF: $app"
  local details
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  case "$details" in
    *"Signature=adhoc"*) fail "ad-hoc подпись в выпуске: $app" ;;
  esac
  case "$details" in
    *"Authority=$IDENTITY"*) ;;
    *) fail "приложение подписано не этой identity: $app" ;;
  esac
}

for label in arm64 intel; do
  app="$DIST/Runvoice-$label.app"
  [ -d "$app" ] || fail "нет приложения: $app"

  if [ "$label" = "arm64" ]; then
    sign_binary "$app/Contents/Resources/RunvoiceASR"
  fi
  sign_binary "$app/Contents/Resources/whisper/bin/runvoice-vad"
  sign_binary "$app/Contents/Resources/whisper/bin/whisper-server"
  sign_binary "$app/Contents/Resources/whisper/bin/whisper-cli"
  sign_binary "$app/Contents/Resources/pastev"
  codesign --force --deep --sign "$IDENTITY" "$app" >/dev/null
  check_app "$app"
done

RUNVOICE_SIGN_IDENTITY="$IDENTITY" "$REPO/scripts/make-dmg.sh" >/dev/null

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIST/Runvoice-arm64.app/Contents/Info.plist")"
for label in arm64 intel; do
  dmg="$DIST/Runvoice-$version-$label.dmg"
  [ -f "$dmg" ] || fail "DMG не создан: $dmg"
  codesign --verify "$dmg" >/dev/null 2>&1 || fail "образ не подписан: $dmg"
  details="$(codesign -dv --verbose=4 "$dmg" 2>&1)"
  case "$details" in
    *"Signature=adhoc"*) fail "ad-hoc образ в выпуске: $dmg" ;;
  esac
  case "$details" in
    *"Authority=$IDENTITY"*) ;;
    *) fail "образ подписан не этой identity: $dmg" ;;
  esac
  hdiutil verify "$dmg" >/dev/null
  [ -f "$dmg.sha256" ] || fail "нет контрольной суммы: $dmg"
done

echo "OK: приложения и образы подписаны Runvoice Local Signing (leaf $EXPECTED_LEAF)"
