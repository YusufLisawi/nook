#!/bin/zsh
# After ./scripts/release.sh: sign the DMG for Sparkle, add it to site/appcast.xml, create the GitHub release,
# push, and redeploy the site. Usage: ./scripts/publish.sh notes.md
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?usage: publish.sh notes.md}
APP=build/Build/Products/Release/Nook.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
SPARKLE_BIN=${SPARKLE_BIN:-$HOME/Developer/_ext/sparkle/bin}
xcrun stapler validate dist/Nook.dmg >/dev/null || { echo "dist/Nook.dmg isn't notarized — run release.sh first"; exit 1; }

# EdDSA signature with the private key in the keychain (account "nook").
SIG=$("$SPARKLE_BIN/sign_update" --account nook dist/Nook.dmg)   # → sparkle:edSignature="…" length="…"
URL="https://github.com/YusufLisawi/nook/releases/download/v$VERSION/Nook.dmg"
HTML=$(python3 -c "
import html,sys
out=[]
for line in open(sys.argv[1]).read().splitlines():
    t=line.strip()
    if not t: continue
    if t.startswith('- '): out.append('<li>'+html.escape(t[2:]).replace('**','')+'</li>')
    elif t.startswith('#'): out.append('<h3>'+html.escape(t.lstrip('# '))+'</h3>')
    else: out.append('<p>'+html.escape(t).replace('**','')+'</p>')
print(''.join(out))" "$NOTES")

python3 - "$VERSION" "$BUILD" "$URL" "$SIG" "$HTML" <<'PY'
import sys, os, email.utils
version, build, url, sig, notes = sys.argv[1:]
path = "site/appcast.xml"
head = '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel>\n<title>Nook</title>\n<link>https://nook.motkan.com</link>\n'
body = open(path).read().split("<link>https://nook.motkan.com</link>\n", 1)[1] if os.path.exists(path) else "</channel>\n</rss>\n"
if f"<sparkle:version>{build}</sparkle:version>" in body:
    sys.exit(f"build {build} is already in the appcast — bump CFBundleVersion")
item = f"""<item>
  <title>Nook {version}</title>
  <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
  <sparkle:version>{build}</sparkle:version>
  <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
  <description><![CDATA[{notes}]]></description>
  <enclosure url="{url}" type="application/octet-stream" {sig}/>
</item>
"""
open(path, "w").write(head + item + body)
print("appcast: added", version, f"(build {build})")
PY

gh release create "v$VERSION" dist/Nook.dmg --repo YusufLisawi/nook --title "Nook $VERSION" --notes-file "$NOTES" --latest
git add site/appcast.xml && git commit -qm "Appcast: Nook $VERSION" && git push -q origin main
coolify deploy uuid c0eavfha70p6pxmafnrj6atc >/dev/null 2>&1 || echo "! redeploy the site in Coolify (nook-landing)"
echo "✓ Published Nook $VERSION — existing installs will offer it within a day (or Check for Updates…)"
