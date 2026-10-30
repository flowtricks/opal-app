#!/bin/bash
# Universal stock-UVC app, with no experimental firmware-loading backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
# The read-only update token is passed through the environment so it never
# appears in the command line or build log; Info.plist expands it.
TOKEN_FILE=Config/update-token.local
[[ -s "$TOKEN_FILE" ]] || { echo "Missing $TOKEN_FILE (read-only GitHub token for private updates)" >&2; exit 1; }
OPAL_UPDATE_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
export OPAL_UPDATE_TOKEN
python3 scripts/generate-xcode-project.py --without-experimental-runtime
xcodebuild -project OpalStudio.xcodeproj -scheme OpalStudioNative \
  -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  -archivePath build/OpalStudio.xcarchive \
  -derivedDataPath build/DistributionDerivedData \
  -allowProvisioningUpdates archive
