#!/usr/bin/env bash
# bundle-whisper.sh — собирает универсальные (arm64 + x86_64) статические
# whisper-server/whisper-cli и кладёт их в бандл. Модели сюда не входят.
#
# Использование: bundle-whisper.sh <каталог назначения>
#   например: bundle-whisper.sh dist/Runvoice.app/Contents/Resources/whisper
#
# Первая сборка требует cmake и сеть (клонируется whisper.cpp v1.9.5).
# Дальше используется кэш в .build/whisper-src/build*.
set -euo pipefail

DEST="${1:?укажите каталог назначения}"
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
WANT="v1.9.5-macos13-universal"

if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$ARM_BUILD" "$X86_BUILD"
fi

command -v cmake >/dev/null 2>&1 || {
  echo "нужен cmake: brew install cmake" >&2; exit 1; }

if [ ! -x "$ARM_SERVER" ] || [ ! -x "$ARM_CLI" ]; then
  echo "==> whisper.cpp: arm64 (Metal, macOS 13+)"
  cmake -B "$ARM_BUILD" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
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
  echo "==> whisper.cpp: x86_64 (CPU, macOS 13+)"
  cmake -B "$X86_BUILD" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
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

lipo -create "$ARM_SERVER" "$X86_SERVER" -output "$DEST/bin/whisper-server"
lipo -create "$ARM_CLI" "$X86_CLI" -output "$DEST/bin/whisper-cli"
chmod +x "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"
printf '%s' "$WANT" > "$STAMP"

for f in "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"; do
  if ! lipo -info "$f" | grep -q 'x86_64' || ! lipo -info "$f" | grep -q 'arm64'; then
    echo "бинарник $f не универсальный:" >&2
    lipo -info "$f" >&2
    exit 1
  fi
  for arch in arm64 x86_64; do
    if otool -arch "$arch" -L "$f" | grep -q '/opt/homebrew'; then
      echo "бинарник $f ($arch) зависит от Homebrew:" >&2
      otool -arch "$arch" -L "$f" >&2
      exit 1
    fi
  done
done

echo "    whisper: встроен ($(du -sh "$DEST" | cut -f1), arm64 + x86_64)"
