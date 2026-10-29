#!/bin/bash
# Sign using Developer ID profiles, which do not require registering each Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -exportArchive -archivePath build/OpalStudio.xcarchive \
  -exportPath build/DeveloperID \
  -exportOptionsPlist Config/ExportOptions-DeveloperID.plist \
  -allowProvisioningUpdates
