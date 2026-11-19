#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/api-tests"
mkdir -p "$BUILD"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$REPO/app" -name '*.swift' ! -name main.swift ! -name AppDelegate.swift -print | sort
)
swiftc -parse-as-library -target "$(uname -m)-apple-macos15.0" -module-cache-path "$REPO/.build/clang-module-cache" \
  "${SOURCES[@]}" "$REPO/tests/api/main.swift" -o "$BUILD/tests"
runvoice_api_home=$(mktemp -d "$BUILD/home.XXXXXX")
trap 'rm -rf "$runvoice_api_home"' EXIT
env CFFIXED_USER_HOME="$runvoice_api_home" "$BUILD/tests" "$@"
