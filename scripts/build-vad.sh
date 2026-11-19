#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${2:?architecture}"
SRC="$REPO/.build/whisper-src"
case "$ARCH" in arm64) BUILD="$SRC/build";; x86_64) BUILD="$SRC/build-x86_64";; *) exit 2;; esac
LIBS=("$BUILD/src/libwhisper.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-cpu.a")
if [ "$ARCH" = arm64 ]; then LIBS+=("$BUILD/ggml/src/ggml-metal/libggml-metal.a"); fi
LIBS+=("$BUILD/ggml/src/libggml-base.a")
FRAMEWORKS=(-framework Accelerate)
if [ "$ARCH" = arm64 ]; then FRAMEWORKS+=(-framework Foundation -framework Metal -framework MetalKit); fi
c++ -O3 -std=c++17 -arch "$ARCH" -mmacosx-version-min=15.0 -I "$SRC/include" -I "$SRC/ggml/include" \
 "$REPO/bin/runvoice-vad.cpp" "${LIBS[@]}" "${FRAMEWORKS[@]}" -o "$1"
