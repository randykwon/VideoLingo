#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
BUILD_DIR="$ROOT_DIR/.build/DerivedData"
APP_PATH="$BUILD_DIR/Build/Products/Release/VideoLingo.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Sources/VideoLingo/Info.plist")
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/VideoLingo-$VERSION.dmg"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/videolingo-dmg.XXXXXX")

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build_app.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
ditto "$APP_PATH" "$STAGING_DIR/VideoLingo.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "VideoLingo" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
echo "DMG: $DMG_PATH"
