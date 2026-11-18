#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/.build/vad"
MODEL="$REPO/.build/vad/ggml-silero-v5.1.2.bin"
if [ ! -f "$MODEL" ]; then
 curl -fL --retry 2 https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin -o "$MODEL"
fi
# Локально модель проверяется по закреплённому хешу ниже.
[ "$(shasum -a 256 "$MODEL" | cut -d ' ' -f 1)" = 29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf ] || { echo 'Неверная SHA-256 VAD-модели' >&2; exit 1; }
