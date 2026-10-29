#!/bin/bash
# Universal stock-UVC app, with no experimental firmware-loading backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
python3 scripts/generate-xcode-project.py --without-experimental-runtime
xcodebuild -project OpalStudio.xcodeproj -scheme OpalStudioNative \
  -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  -archivePath build/OpalStudio.xcarchive \
  -derivedDataPath build/DistributionDerivedData \
  -allowProvisioningUpdates archive
