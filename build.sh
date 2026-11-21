#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="vpointer"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Use CommandLineTools in case the Xcode.app license has not been accepted yet
if [ -d "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Building $APP_NAME ($ARCH)..."
swiftc \
    -O \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-macosx13.0" \
    -framework AppKit \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -o "$MACOS_DIR/$APP_NAME" \
    "$ROOT_DIR/Sources/vpointer/ScrollManager.swift" \
    "$ROOT_DIR/Sources/vpointer/MouseMonitor.swift" \
    "$ROOT_DIR/Sources/vpointer/MiddleClickManager.swift" \
    "$ROOT_DIR/Sources/vpointer/AppDelegate.swift" \
    "$ROOT_DIR/Sources/vpointer/main.swift"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Ad-hoc code signing for local macOS execution
codesign --force --deep --sign - "$APP_BUNDLE"

echo "App built successfully at: $APP_BUNDLE"
