#!/bin/bash
# Build a portable drag-to-Applications disk image from a verified notarized app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="${1:-$(cat build/notarized-app-path.txt)}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Timothy Ricks (G766RX9X84)}"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
for binary in "$APP/Contents/MacOS/OpalStudio" \
              "$APP/Contents/MacOS/OpalCameraLaunchAgent" \
              "$APP/Contents/Library/SystemExtensions/com.timothyricks.opal-app.camera.systemextension/Contents/MacOS/CameraExtension"; do
  SLICES=" $(lipo "$binary" -archs) "
  [[ "$SLICES" == *" arm64 "* && "$SLICES" == *" x86_64 "* ]] || exit 1
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
mkdir -p build dist
DMG="Opal-Studio-${VERSION}-${BUILD}-universal.dmg"
[[ ! -e "dist/$DMG" ]] || { echo "Refusing to overwrite dist/$DMG" >&2; exit 1; }
STAGING=$(mktemp -d "$ROOT/build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Opal Studio.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install Opal Studio.txt" <<'GUIDE'
Opal Studio — macOS 14 or later

1. Drag Opal Studio into Applications.
2. Eject this disk image and open Opal Studio from Applications.
3. Grant Camera access when macOS asks.
4. For meeting output, open Settings → Video in Opal Studio, click
   Install Camera Extension, and enable Opal Studio Camera in
   System Settings → General → Login Items & Extensions → Camera Extensions.
5. Select Opal Studio Camera in Zoom, Google Meet, or your other camera app.

Each Mac needs its own camera/extension permissions. Apple Silicon and Intel
executables are included. No developer account or device registration is needed.

Settings → General controls launch at login and launch when the C1 is connected.
Quit the original Composer camera connection before using the C1 in Studio.
Your presets/settings remain stored locally on each Mac; import an .opalPreset
through the Presets menu to bring a preset to another Mac.
GUIDE
hdiutil create -volname 'Opal Studio' -srcfolder "$STAGING" -fs HFS+ -format UDZO "dist/$DMG"
codesign --force --timestamp --sign "$IDENTITY" "dist/$DMG"
codesign --verify --strict "dist/$DMG"
hdiutil verify "dist/$DMG"
(cd dist && shasum -a 256 "$DMG" > "$DMG.sha256")
printf 'Verified disk image containing notarized app: %s/dist/%s\n' "$ROOT" "$DMG"
