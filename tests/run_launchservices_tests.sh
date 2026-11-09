#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(git rev-parse --show-toplevel)/../../../temp/launchservices"
BINARY=$OUT/WQLaunchServicesTests
mkdir -p "$OUT"
cleanup() {
    rm -rf "$OUT"
}
trap cleanup EXIT
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -fobjc-arc -fmodules -isysroot "$MACOS_SDK" \
    -Wall -Wextra -Werror -I. WQLaunchServices.m tests/WQLaunchServicesTests.m \
    -framework Foundation -o "$BINARY"
"$BINARY"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -fobjc-arc -fmodules -isysroot "$IOS_SDK" \
    -miphoneos-version-min=17.0 -Wall -Wextra -Werror -I. -fsyntax-only \
    WQLaunchServices.m tests/WQLaunchServicesTests.m
