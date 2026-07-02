#!/bin/bash
set -euo pipefail

APP_PATH="build/Build/Products/Release/Myae.app"
DMG_NAME="${1:+MyaeEditor-${1}.dmg}"
DMG_NAME="${DMG_NAME:-MyaeEditor.dmg}"

echo "Building MyaeEditor..."

xcodebuild \
  -project MyaeEditor.xcodeproj \
  -scheme MyaeEditor \
  -configuration Release \
  -derivedDataPath build \
  -arch arm64 \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  build

echo "Creating DMG..."

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "Error: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING_DIR/"

rm -f "$DMG_NAME"
create-dmg \
  --volname "MyaeEditor" \
  --background "resources/background.tiff" \
  --window-pos 200 120 \
  --window-size 540 410 \
  --icon-size 128 \
  --icon "Myae.app" 100 220 \
  --app-drop-link 400 220 \
  --hide-extension "Myae.app" \
  --no-internet-enable \
  "$DMG_NAME" \
  "$STAGING_DIR"

rm -rf "$STAGING_DIR"

echo "Done: $DMG_NAME"
