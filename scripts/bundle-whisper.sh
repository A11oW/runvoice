#!/usr/bin/env bash
# bundle-whisper.sh — собирает статические whisper-server/whisper-cli
# для одной архитектуры и кладёт их в бандл. Модели сюда не входят.
#
# Использование: bundle-whisper.sh <каталог назначения> [arm64|x86_64]
#   например: bundle-whisper.sh dist/Runvoice-arm64.app/Contents/Resources/whisper arm64
#
# Первая сборка требует cmake и сеть (клонируется whisper.cpp v1.9.5).
# Дальше используется кэш в .build/whisper-src/build*.
set -euo pipefail

DEST="${1:?укажите каталог назначения}"
ARCH="${2:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "неизвестная архитектура: $ARCH" >&2; exit 2 ;;
esac
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/.build"
SRC="$BUILD/whisper-src"
VERSION="${WHISPER_CPP_VERSION:-v1.9.5}"

mkdir -p "$DEST/bin"

if [ ! -d "$SRC/.git" ]; then
  echo "==> whisper.cpp $VERSION: клон"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$SRC" >/dev/null
fi

ARM_BUILD="$SRC/build"
X86_BUILD="$SRC/build-x86_64"
ARM_SERVER="$ARM_BUILD/bin/whisper-server"
ARM_CLI="$ARM_BUILD/bin/whisper-cli"
X86_SERVER="$X86_BUILD/bin/whisper-server"
X86_CLI="$X86_BUILD/bin/whisper-cli"
STAMP="$BUILD/whisper-build.stamp"
WANT="v1.9.5-macos15-universal"

if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$ARM_BUILD" "$X86_BUILD"
fi

command -v cmake >/dev/null 2>&1 || {
  echo "нужен cmake: brew install cmake" >&2; exit 1; }

if [ ! -x "$ARM_SERVER" ] || [ ! -x "$ARM_CLI" ]; then
  echo "==> whisper.cpp: arm64 (Metal, macOS 15+)"
  cmake -B "$ARM_BUILD" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_SERVER=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DGGML_METAL=ON \
    -DGGML_BLAS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_OPENMP=OFF >/dev/null
  cmake --build "$ARM_BUILD" --target whisper-server whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
fi

if [ ! -x "$X86_SERVER" ] || [ ! -x "$X86_CLI" ]; then
  echo "==> whisper.cpp: x86_64 (CPU, macOS 15+)"
  cmake -B "$X86_BUILD" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_SERVER=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF >/dev/null
  cmake --build "$X86_BUILD" --target whisper-server whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
fi

case "$ARCH" in
  arm64)
    cp "$ARM_SERVER" "$DEST/bin/whisper-server"
    cp "$ARM_CLI" "$DEST/bin/whisper-cli"
    ;;
  x86_64)
    cp "$X86_SERVER" "$DEST/bin/whisper-server"
    cp "$X86_CLI" "$DEST/bin/whisper-cli"
    ;;
esac
chmod +x "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"
printf '%s' "$WANT" > "$STAMP"

for f in "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"; do
  if ! lipo -info "$f" | grep -q "$ARCH"; then
    echo "бинарник $f не для $ARCH:" >&2
    lipo -info "$f" >&2
    exit 1
  fi
  if otool -arch "$ARCH" -L "$f" | grep -q '/opt/homebrew'; then
    echo "бинарник $f зависит от Homebrew:" >&2
    otool -arch "$ARCH" -L "$f" >&2
    exit 1
  fi
done

echo "    whisper: встроен ($(du -sh "$DEST" | cut -f1), $ARCH)"
