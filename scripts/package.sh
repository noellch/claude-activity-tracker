#!/bin/bash
set -e

APP_NAME="ClaudeActivityTracker"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
STAGING_DIR=".build/package"

echo "=== Building release binary ==="
swift build -c release

echo "=== Creating .app bundle ==="
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${STAGING_DIR}/${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${STAGING_DIR}/${APP_BUNDLE}/Contents/MacOS/"

# Create Info.plist
cat > "${STAGING_DIR}/${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claude Activity Tracker</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Activity Tracker</string>
    <key>CFBundleIdentifier</key>
    <string>com.noellch.claude-activity-tracker</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeActivityTracker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "=== Code signing (ad-hoc) ==="
codesign --force --deep -s - "${STAGING_DIR}/${APP_BUNDLE}"

echo "=== Creating DMG ==="
rm -f "${DMG_NAME}"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}/${APP_BUNDLE}" \
    -ov -format UDZO \
    "${DMG_NAME}"

echo ""
echo "=== Done ==="
echo "  App bundle: ${STAGING_DIR}/${APP_BUNDLE}"
echo "  DMG: ${DMG_NAME}"
echo ""
echo "To install: open ${DMG_NAME} and drag to /Applications"
