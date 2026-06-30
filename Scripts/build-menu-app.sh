#!/bin/bash
# build-menu-app.sh — Build Rec menu bar app and wrap it in a .app bundle
#
# Usage:
#   ./Scripts/build-menu-app.sh                    # build Rec.app to /tmp/
#   ./Scripts/build-menu-app.sh --install [path]   # build + install to path
#
# When --install is given without a path, installs to ~/Applications/.
#
# Uses a temporary scratch path to avoid permission issues in .build/
# (which may have root-owned leftovers from sudo builds).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Rec"
SPM_PRODUCT="RecMenu"
BUNDLE_ID="com.record.rec"

# Use a temp scratch dir to avoid root-owned artifacts in .build/
SCRATCH_DIR="${SCRATCH_DIR:-${TMPDIR:-/tmp}/rec-menu-build-$$}"
APP_BUNDLE="${APP_BUNDLE:-${TMPDIR:-/tmp}/$APP_NAME.app}"

# Clean up any leftover from a previous run
rm -rf "$APP_BUNDLE" 2>/dev/null || true

# Build (or skip if SKIP_BUILD is set and binary exists)
if [ "${SKIP_BUILD:-}" != "1" ] || [ ! -f "$SCRATCH_DIR/release/$SPM_PRODUCT" ]; then
    echo "==> Building $SPM_PRODUCT (release)..."
    rm -rf "$SCRATCH_DIR" 2>/dev/null || true
    swift build -c release --product "$SPM_PRODUCT" --scratch-path "$SCRATCH_DIR"
fi

BINARY="$SCRATCH_DIR/release/$SPM_PRODUCT"
if [ ! -f "$BINARY" ]; then
    echo "Error: built binary not found at $BINARY"
    exit 1
fi

echo "==> Creating .app bundle at $APP_BUNDLE..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon
ICON_SRC="$PROJECT_DIR/Sources/RecMenu/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Rec needs microphone access to start recordings</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Bundle created: $APP_BUNDLE"

# Handle --install
if [ "${1:-}" = "--install" ]; then
    INSTALL_TARGET="${2:-$HOME/Applications}"
    mkdir -p "$INSTALL_TARGET"
    rm -rf "$INSTALL_TARGET/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "$INSTALL_TARGET/"
    echo "==> Installed to $INSTALL_TARGET/$APP_NAME.app"
    echo "==> Launch from Spotlight as \"$APP_NAME\""
fi

# Clean up scratch
rm -rf "$SCRATCH_DIR" 2>/dev/null || true

echo "==> Done"
