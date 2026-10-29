#!/bin/bash
# Refuses to package unless Apple notarization, signatures and both slices pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -exportNotarizedApp -archivePath build/OpalStudio.xcarchive \
  -exportPath build/Notarized
APP="$ROOT/build/Notarized/OpalStudio.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
for binary in "$APP/Contents/MacOS/OpalStudio" \
              "$APP/Contents/MacOS/OpalCameraLaunchAgent" \
              "$APP/Contents/Library/SystemExtensions/com.timothyricks.opal-app.camera.systemextension/Contents/MacOS/CameraExtension"; do
  lipo -verify_arch arm64 x86_64 "$binary"
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="Opal-Studio-${VERSION}-${BUILD}-universal.zip"
# ditto preserves the stapled ticket, signatures, bundle symlinks and metadata.
ditto -c -k --keepParent "$APP" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
printf 'Verified release: %s/dist/%s\n' "$ROOT" "$ZIP"
