#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/.build/update-tests"
swiftc -target "$(uname -m)-apple-macos15.0" -module-cache-path "$REPO/.build/clang-module-cache" \
 "$REPO/app/Core/UpdateCoordinator.swift" "$REPO/app/UI/UpdateBadgeView.swift" "$REPO/tests/updates/main.swift" -o "$REPO/.build/update-tests/tests"
"$REPO/.build/update-tests/tests"
