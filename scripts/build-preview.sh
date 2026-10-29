#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product OpalStudio
APP="$PWD/build/Opal Studio Preview.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OpalStudio "$APP/Contents/MacOS/OpalStudio"
cp Config/App-Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.timothyricks.opal-app.preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName Opal Studio Preview' "$APP/Contents/Info.plist"
codesign --force --sign 'Developer ID Application: Timothy Ricks (G766RX9X84)' --options runtime --entitlements Config/Preview.entitlements "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
