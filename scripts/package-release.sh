#!/bin/bash
# Refuses to package unless Apple notarization, signatures and both slices pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCHIVE="${1:-build/OpalStudio.xcarchive}"
EXPORT_DIR=$(mktemp -d "$ROOT/build/notarized.XXXXXX")
xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR"
APP="$EXPORT_DIR/OpalStudio.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
for binary in "$APP/Contents/MacOS/OpalStudio" \
              "$APP/Contents/MacOS/OpalCameraLaunchAgent" \
              "$APP/Contents/Library/SystemExtensions/com.timothyricks.opal-app.camera.systemextension/Contents/MacOS/CameraExtension"; do
  SLICES=" $(lipo "$binary" -archs) "
  [[ "$SLICES" == *" arm64 "* && "$SLICES" == *" x86_64 "* ]] || {
    echo "Missing universal architecture in $binary" >&2; exit 1;
  }
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="Opal-Studio-${VERSION}-${BUILD}-universal.zip"
# ditto preserves the stapled ticket, signatures, bundle symlinks and metadata.
ditto -c -k --keepParent "$APP" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
printf '%s\n' "$APP" > build/notarized-app-path.txt
printf 'Verified release: %s/dist/%s\n' "$ROOT" "$ZIP"
