#!/bin/zsh
# Build a universal Release of Nook and package it as dist/Nook.dmg (drag-to-Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build \
  ONLY_ACTIVE_ARCH=NO build | grep -E "error:|BUILD" || true
APP=build/Build/Products/Release/Nook.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Nook $VERSION — $(lipo -archs "$APP/Contents/MacOS/Nook")"

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Nook.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
[ -e dist/Nook.dmg ] && trash dist/Nook.dmg
hdiutil create -volname "Nook $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ dist/Nook.dmg >/dev/null
trash "$STAGE"
echo "dist/Nook.dmg ($(du -h dist/Nook.dmg | cut -f1))"
