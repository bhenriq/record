#!/bin/bash
# build-menu-app.sh — Build RecMenu and wrap it in a .app bundle
#
# Usage:
#   ./Scripts/build-menu-app.sh [--install]
#
# Without --install: creates RecMenu.app in .build/RecMenu.app
# With --install: also copies it to ~/Applications/

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="RecMenu"
BUNDLE_ID="com.record.rec-menu"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building $APP_NAME (release)..."
swift build -c release --product "$APP_NAME"

BINARY="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "Error: built binary not found at $BINARY"
    exit 1
fi

echo "==> Creating .app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp "$BINARY" "$MACOS/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RecMenu needs microphone access to start recordings</string>
</dict>
</plist>
EOF

# Create PkgInfo (required for some macOS versions)
echo "APPL????" > "$CONTENTS/PkgInfo"

echo "==> Bundle created: $APP_BUNDLE"

if [ "${1:-}" = "--install" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    cp -R "$APP_BUNDLE" "$INSTALL_DIR/"
    echo "==> Installed to $INSTALL_DIR/$APP_NAME.app"
    echo "==> You can now launch it from Spotlight or ~/Applications"
fi

echo "==> Done"
