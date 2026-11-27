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

mkdir -p "$DIST_DIR"
ditto "$APP_PATH" "$STAGING_DIR/VAutoLang.app"

# 내장 Metal 런타임(whisper-server / llama-server)이 준비되어 있으면 앱 번들에 포함해
# 다른 Apple Silicon Mac에서도 추가 빌드 없이 바로 사용할 수 있게 합니다.
RUNTIME_SRC="${HOME}/Library/Application Support/VideoLingo/ManagedRuntime"
if [[ -x "$RUNTIME_SRC/whisper-server" && -x "$RUNTIME_SRC/llama-server" ]]; then
  RUNTIME_DST="$STAGING_DIR/VAutoLang.app/Contents/Resources/ManagedRuntime"
  mkdir -p "$RUNTIME_DST"
  cp -f "$RUNTIME_SRC/whisper-server" "$RUNTIME_DST/whisper-server"
  cp -f "$RUNTIME_SRC/llama-server" "$RUNTIME_DST/llama-server"
  chmod +x "$RUNTIME_DST/whisper-server" "$RUNTIME_DST/llama-server"
  for doc in whisper-LICENSE llama-LICENSE THIRD_PARTY_LICENSES.txt ManagedRuntimeNotice.md; do
    [[ -f "$RUNTIME_SRC/$doc" ]] && cp -f "$RUNTIME_SRC/$doc" "$RUNTIME_DST/$doc"
  done
  codesign --force --sign - --timestamp=none "$RUNTIME_DST/whisper-server"
  codesign --force --sign - --timestamp=none "$RUNTIME_DST/llama-server"
  # 리소스를 추가했으므로 앱 번들 서명을 갱신해 다른 Mac에서도 codesign 무결성 검증을 통과하도록 합니다.
  xattr -cr "$STAGING_DIR/VAutoLang.app"
  codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements,flags "$STAGING_DIR/VAutoLang.app"
fi

codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/VAutoLang.app"
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
