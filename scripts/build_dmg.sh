#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
BUILD_DIR="$ROOT_DIR/.build/DerivedData"
APP_PATH="$BUILD_DIR/Build/Products/Release/VAutoLang.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/videolingo-dmg.XXXXXX")

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build_app.sh"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
if [[ -z "$VERSION" || "$VERSION" == *'$('* ]]; then
  echo "error: 앱 번들에서 유효한 버전을 읽지 못했습니다: '$VERSION'" >&2
  exit 1
fi
DMG_PATH="$DIST_DIR/VAutoLang-$VERSION.dmg"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
ditto "$APP_PATH" "$STAGING_DIR/VAutoLang.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "VAutoLang" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
echo "DMG: $DMG_PATH"
