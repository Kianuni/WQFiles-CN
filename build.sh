#!/usr/bin/env bash
# Builds WQFiles.ipa (arm64, ad-hoc signed with the App Group entitlement;
# re-sign with your sideloading tool, keeping an App Group).
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
APP=$OUT/Payload/WQFiles.app
rm -rf "$OUT"; mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -arch arm64 -miphoneos-version-min=17.0 \
    -isysroot "$SDK" -Wall -Wextra -Werror -O2 \
    -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers \
    WQCore.m WQAccess.m WQUI.m WQSharing.m WQApps.m WQCache.m WQPlistEditor.m WQHexViewer.m main.m -o "$APP/WQFiles"
cp Info.plist "$APP/Info.plist"
cp icons/AppIcon*@*.png "$APP/"
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --entitlements entitlements.plist "$APP"
(cd "$OUT" && zip -qry ../WQFiles.ipa Payload)
rm -rf "$OUT"
echo "wrote $(pwd)/WQFiles.ipa"
