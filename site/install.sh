#!/bin/bash
# Nook installer: curl -fsSL https://nook.motkan.com/install.sh | bash
# Downloads the latest release and installs it to /Applications (files fetched by curl aren't quarantined,
# so macOS doesn't show the "could not verify" dialog).
set -euo pipefail
URL="https://github.com/YusufLisawi/nook/releases/latest/download/Nook.dmg"
TMP=$(mktemp -d)
echo "↓ Downloading Nook…"
curl -fL --progress-bar "$URL" -o "$TMP/Nook.dmg"
MNT=$(hdiutil attach -nobrowse -readonly "$TMP/Nook.dmg" | tail -1 | cut -f3)
osascript -e 'tell application "Nook" to quit' >/dev/null 2>&1 || true
sleep 1
echo "→ Installing to /Applications"
ditto "$MNT/Nook.app" /Applications/Nook.app
hdiutil detach "$MNT" >/dev/null
xattr -dr com.apple.quarantine /Applications/Nook.app 2>/dev/null || true
mv "$TMP/Nook.dmg" "$HOME/.Trash/Nook-installer-$(date +%s).dmg" 2>/dev/null || true
open /Applications/Nook.app
echo "✓ Nook is running — look at your notch."
