#!/bin/zsh
# Builds the downloadable installer: dist/FocusDim.dmg
# - Universal app (Apple silicon + Intel), macOS 13+
# - Disk image with FocusDim.app and an Applications shortcut (drag to install)
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
OUT=dist
STAGE=$OUT/stage
APP=$STAGE/FocusDim.app
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macos13  main.swift -o "$OUT/FocusDim-arm64"
swiftc -O -target x86_64-apple-macos13 main.swift -o "$OUT/FocusDim-x86_64"
lipo -create "$OUT/FocusDim-arm64" "$OUT/FocusDim-x86_64" -output "$APP/Contents/MacOS/FocusDim"
rm "$OUT/FocusDim-arm64" "$OUT/FocusDim-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "FocusDim $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/FocusDim.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built $(pwd)/$OUT/FocusDim.dmg (version $VERSION)"
