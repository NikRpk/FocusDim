#!/bin/zsh
# Developer build: compiles FocusDim.app for this Mac and installs it to ~/Applications.
# To make the downloadable installer for other people, use release.sh instead.
set -e
cd "$(dirname "$0")"
APP=FocusDim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/FocusDim"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

# Install to ~/Applications so "Start at login" points at a fixed place.
pkill -x FocusDim 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/FocusDim.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/FocusDim.app"

# A new build has a new signature, so macOS forgets the old Accessibility
# permission. Clear the stale entry so FocusDim asks again cleanly.
tccutil reset Accessibility com.nropke.focusdim >/dev/null 2>&1 || true
