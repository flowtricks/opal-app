#!/bin/bash
# Uses the developer account already signed in to Xcode; no credentials in source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -exportArchive -archivePath build/OpalStudio.xcarchive \
  -exportPath build/Notarization \
  -exportOptionsPlist Config/ExportOptions-Notarize.plist \
  -allowProvisioningUpdates
printf '%s\n' 'Submitted to Apple. Once processing completes, run scripts/package-release.sh.'
