#!/usr/bin/env bash
# Builds the iOS app and uploads it to TestFlight.
#
# Required environment variables:
#   APPLE_TEAM_ID      Your 10-character Apple Developer Team ID
#   ASC_KEY_ID         App Store Connect API key ID
#   ASC_ISSUER_ID      App Store Connect API issuer ID
#   ASC_KEY_PATH       Path to the downloaded AuthKey_XXXX.p8 file
# Optional:
#   GOOGLE_CLIENT_ID   Google OAuth iOS client ID (enables Gmail/Calendar/Tasks)
#   BUILD_NUMBER       Defaults to a timestamp so every upload is unique
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

if [[ -n "${GOOGLE_CLIENT_ID:-}" ]]; then
  REVERSED=$(echo "$GOOGLE_CLIENT_ID" | awk -F. '{for (i=NF; i>0; i--) printf "%s%s", $i, (i>1 ? "." : "")}')
  cat > Config.local.xcconfig <<CONFIG
DEVELOPMENT_TEAM = $APPLE_TEAM_ID
GOOGLE_CLIENT_ID = $GOOGLE_CLIENT_ID
GOOGLE_REVERSED_CLIENT_ID = $REVERSED
CONFIG
fi

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

rm -rf build && mkdir -p build
sed "s/TEAM_ID_PLACEHOLDER/$APPLE_TEAM_ID/" scripts/ExportOptions.plist > build/ExportOptions.plist

echo "▶ Archiving TaskHub (build $BUILD_NUMBER)…"
xcodebuild archive \
  -project TaskHub.xcodeproj \
  -scheme TaskHub-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/TaskHub.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}"

echo "▶ Uploading to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath build/TaskHub.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export \
  "${AUTH[@]}"

echo "✅ Uploaded build $BUILD_NUMBER. It appears in TestFlight after Apple finishes processing (usually 5–15 minutes)."
