#!/bin/bash
# Builds HomeBar.app (a menu bar app with no Dock icon) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HomeBar
swift build -c release --product homebar-cli
BIN="$(swift build -c release --show-bin-path)"

APP="build/HomeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/HomeBar" "$APP/Contents/MacOS/HomeBar"
cp "$BIN/homebar-cli" build/homebar-cli

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HomeBar</string>
    <key>CFBundleDisplayName</key><string>HomeBar</string>
    <key>CFBundleIdentifier</key><string>app.homebar.HomeBar</string>
    <key>CFBundleExecutable</key><string>HomeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Works with SmartRent accounts. Not affiliated with SmartRent.</string>
    <key>NSLocalNetworkUsageDescription</key><string>HomeBar finds and controls your Philips Hue Bridge on your local network.</string>
    <key>NSBonjourServices</key><array><string>_hue._tcp</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature for local use. Use a Developer ID and notarize before you share the app.
codesign --force --sign - "$APP"
echo "Built $APP and build/homebar-cli"
