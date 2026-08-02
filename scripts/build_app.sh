#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
xcodegen generate
xcodebuild \
  -project VideoLingo.xcodeproj \
  -scheme VideoLingo \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_STYLE=Manual \
  build

echo "Built: $PWD/.build/DerivedData/Build/Products/Release/VideoLingo.app"

