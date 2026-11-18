#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$REPO/scripts/prepare-sparkle.sh"
"$REPO/.build/sparkle/bin/generate_keys" --account ai.opencode.runvoice.updates
