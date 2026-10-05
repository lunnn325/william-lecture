#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
xcodegen generate
mkdir -p build dist
xcodebuild -project WilliamLecture.xcodeproj -scheme WilliamLecture \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build -resultBundlePath build/Validation.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | tee build/xcodebuild.log
app="build/Build/Products/Release-iphoneos/WilliamLecture.app"
test -d "$app"
mkdir -p dist/Payload
ditto "$app" dist/Payload/WilliamLecture.app
(cd dist && /usr/bin/zip -qry WilliamLecture-V0-unsigned.ipa Payload)
echo "Unsigned IPA: dist/WilliamLecture-V0-unsigned.ipa (sign locally with Sideloadly)"
