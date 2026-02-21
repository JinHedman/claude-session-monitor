#!/usr/bin/env bash
# Build ClaudeMonitor as a macOS .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OVERLAY_SRC="$PROJECT_ROOT/overlay"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/ClaudeMonitor.app"

echo "==> Building Swift package (release)..."
cd "$OVERLAY_SRC"
swift build -c release

echo "==> Creating .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the release binary into the .app bundle
cp "$OVERLAY_SRC/.build/release/ClaudeMonitor" "$APP_BUNDLE/Contents/MacOS/ClaudeMonitor"

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claude Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Monitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.jinhedman.claude-monitor</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeMonitor</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Done!"
echo "    App bundle: $APP_BUNDLE"
