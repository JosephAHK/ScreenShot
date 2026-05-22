#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ScreenShot"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="arm64-apple-macos14.0"
else
  TARGET="x86_64-apple-macos14.0"
fi

echo "Building $APP_NAME for $TARGET..."
swiftc \
  -parse-as-library \
  -target "$TARGET" \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  "$ROOT/ScreenShot/ScreenShotApp.swift" \
  "$ROOT/ScreenShot/StatusBarController.swift" \
  "$ROOT/ScreenShot/HotkeyManager.swift" \
  "$ROOT/ScreenShot/SelectionOverlayController.swift" \
  "$ROOT/ScreenShot/ScreenCapture.swift" \
  "$ROOT/ScreenShot/CapturesStore.swift"

cp "$ROOT/ScreenShot/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

if [[ -f "$ROOT/ScreenShot/AppIcon.icns" ]]; then
  cp "$ROOT/ScreenShot/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - --identifier com.screenshot.app "$APP_BUNDLE" 2>/dev/null || true

echo "Built: $APP_BUNDLE"
echo "Run: open \"$APP_BUNDLE\""
