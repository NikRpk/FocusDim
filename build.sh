#!/bin/zsh
# Builds FocusDim.app next to this script.
set -e
cd "$(dirname "$0")"
APP=FocusDim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/FocusDim"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FocusDim</string>
  <key>CFBundleIdentifier</key><string>com.nropke.focusdim</string>
  <key>CFBundleExecutable</key><string>FocusDim</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"

# Install to ~/Applications so "Start at login" points at a fixed place.
pkill -x FocusDim 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/FocusDim.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/FocusDim.app"
