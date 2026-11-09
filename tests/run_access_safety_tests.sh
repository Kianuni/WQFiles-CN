#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Generated compiler output stays inside this worktree; fixtures use mktemp-like UUID paths.
OUT=.work/access-tests
mkdir -p "$OUT"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAccessSafetyTests.m \
    -framework Foundation -o "$OUT/WQAccessSafetyTests"
"$OUT/WQAccessSafetyTests"
