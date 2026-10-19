#!/usr/bin/env bash
# bundle-whisper.sh — собирает статические whisper-server/whisper-cli
# и кладёт их в бандл. Модели сюда не входят.
#
# Использование: bundle-whisper.sh <каталог назначения>
#   например: bundle-whisper.sh dist/Runvoice.app/Contents/Resources/whisper
#
# Первая сборка требует cmake и сеть (клонируется whisper.cpp v1.9.5).
# Дальше используется кэш в .build/whisper-src/build.
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

SERVER="$SRC/build/bin/whisper-server"
CLI="$SRC/build/bin/whisper-cli"

if [ ! -x "$SERVER" ] || [ ! -x "$CLI" ]; then
  command -v cmake >/dev/null 2>&1 || {
    echo "нужен cmake: brew install cmake" >&2; exit 1; }

  echo "==> whisper.cpp: статическая сборка"
  cmake -B "$SRC/build" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_SERVER=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DGGML_METAL=ON \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_OPENMP=OFF >/dev/null
  cmake --build "$SRC/build" --target whisper-server whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
fi

cp "$SERVER" "$DEST/bin/whisper-server"
cp "$CLI" "$DEST/bin/whisper-cli"
chmod +x "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"

for f in "$DEST/bin/whisper-server" "$DEST/bin/whisper-cli"; do
  if otool -L "$f" | grep -q '/opt/homebrew'; then
    echo "бинарник $f зависит от Homebrew:" >&2
    otool -L "$f" >&2
    exit 1
  fi
done

echo "    whisper: встроен ($(du -sh "$DEST" | cut -f1))"
