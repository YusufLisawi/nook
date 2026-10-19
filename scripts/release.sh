#!/bin/zsh
# Build → sign → DMG → notarize → staple. Without a "Developer ID Application" certificate it falls back to the
# local signing identity (works, but downloads show Apple's "could not verify" warning).
#
# One-time setup for notarization (needs an Apple Developer account):
#   1. Xcode → Settings → Accounts → (your team) → Manage Certificates → + → Developer ID Application
#   2. xcrun notarytool store-credentials nook --apple-id YOU@MAIL --team-id TEAMID --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."
DEV_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
IDENTITY=${DEV_ID:-"Nook Local Signing"}
echo "Signing as: $IDENTITY"

xcodegen generate >/dev/null
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error:|BUILD" || true
APP=build/Build/Products/Release/Nook.app
# Re-sign inside-out with hardened runtime + secure timestamp (both required by notarization).
codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/nook-cli"
codesign --force --options runtime --timestamp --entitlements Nook/Nook.entitlements -s "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP" && echo "signature ok"

./scripts/make-dmg.sh --skip-build
codesign --force --timestamp -s "$IDENTITY" dist/Nook.dmg

if [[ -n "$DEV_ID" ]] && xcrun notarytool history --keychain-profile nook >/dev/null 2>&1; then
  xcrun notarytool submit dist/Nook.dmg --keychain-profile nook --wait
  xcrun stapler staple dist/Nook.dmg
  spctl -a -t open --context context:primary-signature -v dist/Nook.dmg && echo "✓ Notarized — no Gatekeeper warning"
else
  echo "! Not notarized (no Developer ID or no 'nook' notarytool profile) — users will see Apple's warning on DMG installs."
fi
