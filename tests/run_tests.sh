#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/.build
BINARY=$OUT/WQCoreTests
mkdir -p "$OUT"
cleanup() {
    rm -f "$BINARY"
    rmdir "$OUT" 2>/dev/null || true
}
trap cleanup EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. WQCore.m tests/WQCoreTests.m \
    -framework Foundation -o "$BINARY"
"$BINARY"
