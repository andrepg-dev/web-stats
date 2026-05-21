#!/usr/bin/env bash
set -euo pipefail

swift build -c release --product web-stats
swift build -c release --product web-stats-agent

APP_DIR=".build/web-stats.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/release/web-stats" "$MACOS_DIR/web-stats"
cp ".build/release/web-stats-agent" "$MACOS_DIR/web-stats-agent"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>web-stats</string>
    <key>CFBundleIdentifier</key>
    <string>dev.local.webstats</string>
    <key>CFBundleName</key>
    <string>web-stats</string>
    <key>CFBundleDisplayName</key>
    <string>web-stats</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>web-stats reads Brave's active tab URL to track time spent by website.</string>
</dict>
</plist>
PLIST

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
codesign --force --deep --sign - "$APP_DIR"

echo "Created $APP_DIR"
