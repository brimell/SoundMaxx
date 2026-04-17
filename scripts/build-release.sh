#!/bin/bash

# Build Release script for SoundMaxx
# Creates a DMG installer for distribution

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="SoundMaxx"
DMG_NAME="SoundMaxx-Installer"

echo "=== Building SoundMaxx Release ==="

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build release version
echo "Building release..."
cd "$PROJECT_DIR"
xcodebuild -project SoundMaxx.xcodeproj \
    -scheme SoundMaxx \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    clean build

# Find the built app
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Could not find built app at $APP_PATH"
    exit 1
fi

echo "App built successfully at: $APP_PATH"

# Create DMG
echo "Creating DMG..."
DMG_DIR="$BUILD_DIR/dmg"
mkdir -p "$DMG_DIR"

# Copy app to DMG staging
cp -R "$APP_PATH" "$DMG_DIR/"

# Create symbolic link to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create the DMG
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"

# Use create-dmg for a nicer looking installer
if command -v create-dmg >/dev/null 2>&1; then
    echo "Creating customized DMG with create-dmg..."
    # Use a temp directory for DMG creation to avoid cluttering build dir
    TEMP_DMG_DIR=$(mktemp -d)
    cp -R "$DMG_DIR/" "$TEMP_DMG_DIR/"
    
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "$APP_NAME.app" 180 170 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 480 170 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$TEMP_DMG_DIR"
    
    # Clean up temp directory
    rm -rf "$TEMP_DMG_DIR"
else
    echo "create-dmg not found, using basic hdiutil..."
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo ""
echo "=== Build Complete ==="
echo "DMG created at: $DMG_PATH"
echo ""
echo "To distribute:"
echo "1. For unsigned distribution: Users right-click > Open to bypass Gatekeeper"
echo "2. For signed distribution: Sign with 'codesign' and notarize with 'xcrun notarytool'"
