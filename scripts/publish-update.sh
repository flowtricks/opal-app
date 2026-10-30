#!/bin/bash
# Publish a verified notarized DMG as a private Sparkle update.
# Uploads the DMG to a GitHub release and rewrites updates/appcast.xml;
# the update goes live once that appcast is committed and pushed to main.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="flowtricks/opal-app"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-flowtricks-opal-studio}"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-build/sparkle-tools/bin/sign_update}"
DMG="${1:-$(ls -t dist/Opal-Studio-*-universal.dmg | head -1)}"
NAME="$(basename "$DMG")"
[[ "$NAME" =~ ^Opal-Studio-([0-9.]+)-([0-9]+)-universal\.dmg$ ]] || { echo "Unexpected DMG name: $NAME" >&2; exit 1; }
VERSION="${BASH_REMATCH[1]}"; BUILD="${BASH_REMATCH[2]}"
TAG="v${VERSION}-build${BUILD}"
[[ -x "$SIGN_UPDATE" ]] || { echo "Missing $SIGN_UPDATE (Sparkle 2.10.0 tools)" >&2; exit 1; }

# The packaged DMG must already be Developer ID signed; Sparkle verifies the EdDSA signature too.
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
if [[ -f "$DMG.sha256" ]]; then (cd "$(dirname "$DMG")" && shasum -a 256 -c "$NAME.sha256"); fi

SIGNATURE="$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$DMG")"
[[ "$SIGNATURE" == *'sparkle:edSignature="'* && "$SIGNATURE" == *'length="'* ]] || { echo "sign_update failed" >&2; exit 1; }

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "Opal Studio $VERSION ($BUILD)" --notes "Build $BUILD"
else
  gh release upload "$TAG" "$DMG" --repo "$REPO"
fi
ASSET_ID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$NAME\") | .id")"
[[ "$ASSET_ID" =~ ^[0-9]+$ ]] || { echo "Could not find uploaded asset id" >&2; exit 1; }

mkdir -p updates
cat > updates/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Opal Studio</title>
    <item>
      <title>Opal Studio $VERSION ($BUILD)</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout updates/appcast.xml
printf 'Uploaded %s to release %s (asset %s).\nCommit and push updates/appcast.xml to main to publish the update.\n' "$NAME" "$TAG" "$ASSET_ID"
