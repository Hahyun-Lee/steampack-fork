#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
    echo "A public binary must be Developer ID signed and notarized."
    echo "Set DEVELOPER_ID_APPLICATION and NOTARY_PROFILE; no unsafe unsigned release will be produced."
    exit 2
fi

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM}" "$PROJECT_ROOT/scripts/build.sh"

APP="$PROJECT_ROOT/build/SteamPack.app"
CONTROL_EXTENSION="$APP/Contents/PlugIns/SteamPackControl.appex"
DMG="$PROJECT_ROOT/dist/SteamPack.dmg"

# Sign nested code first and the outer bundle last. Avoid --deep signing: it can
# hide an incomplete bundle graph and is not appropriate for release signing.
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$PROJECT_ROOT/SteamPackControl.entitlements" \
    --sign "$IDENTITY" \
    "$CONTROL_EXTENSION"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$PROJECT_ROOT/SteamPack.entitlements" \
    --sign "$IDENTITY" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

"$PROJECT_ROOT/scripts/create-dmg.sh"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Notarized release: $DMG"
