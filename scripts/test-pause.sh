#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build/pause-tests"
mkdir -p "$BUILD"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$REPO/app" -name '*.swift' ! -name main.swift ! -name AppDelegate.swift -print | sort
)
swiftc -target "$(uname -m)-apple-macos15.0" -D RUNVOICE_TEST_BUILD \
  -module-cache-path "$REPO/.build/clang-module-cache" \
  "${SOURCES[@]}" "$REPO/tests/pause/main.swift" -o "$BUILD/tests"
runvoice_test_home=$(mktemp -d "$BUILD/home.XXXXXX")
trap 'rm -rf "$runvoice_test_home"' EXIT
env CFFIXED_USER_HOME="$runvoice_test_home" "$BUILD/tests"
