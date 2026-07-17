#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
RELEASE_BASE_REF="${RELEASE_BASE_REF:-origin/main}"

# shellcheck source=scripts/release-preflight.sh
source "$PROJECT_ROOT/scripts/release-preflight.sh"

if [ -z "$IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
    echo "A public binary must be Developer ID signed and notarized."
    echo "Set DEVELOPER_ID_APPLICATION and NOTARY_PROFILE; no unsafe unsigned release will be produced."
    exit 2
fi

if [ -z "$RELEASE_TAG" ]; then
    echo "RELEASE_TAG is required, for example v1.4.0-rc.1."
    exit 2
fi

for command_name in git xcodegen xcodebuild codesign security xcrun hdiutil spctl lipo shasum; do
    command -v "$command_name" >/dev/null || {
        echo "Required release command is missing: $command_name" >&2
        exit 2
    }
done

APP_VERSION=$(plist_value "$PROJECT_ROOT/AppInfo.plist" CFBundleShortVersionString)
APP_BUILD=$(plist_value "$PROJECT_ROOT/AppInfo.plist" CFBundleVersion)
PROJECT_VERSION=$(project_setting "$PROJECT_ROOT/project.yml" MARKETING_VERSION)
PROJECT_BUILD=$(project_setting "$PROJECT_ROOT/project.yml" CURRENT_PROJECT_VERSION)

validate_source_versions \
    "$APP_VERSION" \
    "$APP_BUILD" \
    "$PROJECT_VERSION" \
    "$PROJECT_BUILD"
require_release_repository_state \
    "$PROJECT_ROOT" \
    "$RELEASE_BASE_REF" \
    "$RELEASE_TAG" \
    "$APP_VERSION"

IDENTITIES=$(security find-identity -v -p codesigning)
if ! validate_developer_id_identity "$IDENTITIES" "$IDENTITY"; then
    echo "Developer ID identity is not available in the keychain: $IDENTITY" >&2
    exit 2
fi

# Validate the named keychain profile before tests or build output are created.
# This is authoritative for both login-keychain and synchronized profiles.
if ! xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null; then
    echo "Notary profile is missing or unusable: $NOTARY_PROFILE" >&2
    exit 2
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/steampack-release.XXXXXX")
TEST_DERIVED="$WORK_DIR/tests"
RELEASE_DERIVED="$WORK_DIR/release"
STAGED_BUILD="$WORK_DIR/product"
STAGED_DIST="$WORK_DIR/dist"
MOUNT_DIR="$WORK_DIR/mount"
EXTRACTED_APP="$WORK_DIR/extracted/SteamPack.app"
NOTARY_RESULT="$WORK_DIR/notary-result.json"
MOUNTED=0

APP="$STAGED_BUILD/SteamPack.app"
CONTROL_EXTENSION="$APP/Contents/PlugIns/SteamPackControl.appex"
DMG_NAME="SteamPack-${RELEASE_TAG#v}"
DMG="$STAGED_DIST/$DMG_NAME.dmg"
CHECKSUM="$DMG.sha256"
FINAL_DMG="$PROJECT_ROOT/dist/$DMG_NAME.dmg"
FINAL_CHECKSUM="$FINAL_DMG.sha256"

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

cd "$PROJECT_ROOT"
xcodegen generate

xcodebuild \
    -project SteamPack.xcodeproj \
    -scheme SteamPack \
    -configuration Debug \
    -derivedDataPath "$TEST_DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    test

xcodebuild \
    -project SteamPack.xcodeproj \
    -scheme SteamPack \
    -configuration Release \
    -derivedDataPath "$RELEASE_DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO \
    'ARCHS=arm64 x86_64' \
    build

mkdir -p "$STAGED_BUILD" "$STAGED_DIST"
/usr/bin/ditto \
    "$RELEASE_DERIVED/Build/Products/Release/SteamPack.app" \
    "$APP"

BUILT_APP_VERSION=$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)
BUILT_APP_BUILD=$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)
BUILT_EXTENSION_VERSION=$(plist_value "$CONTROL_EXTENSION/Contents/Info.plist" CFBundleShortVersionString)
BUILT_EXTENSION_BUILD=$(plist_value "$CONTROL_EXTENSION/Contents/Info.plist" CFBundleVersion)
validate_bundle_versions "$BUILT_APP_VERSION" "$BUILT_APP_BUILD" "$APP_VERSION" "$APP_BUILD" "app"
validate_bundle_versions \
    "$BUILT_EXTENSION_VERSION" \
    "$BUILT_EXTENSION_BUILD" \
    "$APP_VERSION" \
    "$APP_BUILD" \
    "Control extension"
validate_universal_arches "$(lipo -archs "$APP/Contents/MacOS/SteamPack")"
validate_universal_arches "$(lipo -archs "$CONTROL_EXTENSION/Contents/MacOS/SteamPackControl")"
/usr/bin/plutil -lint "$PROJECT_ROOT/SteamPack.entitlements" >/dev/null
/usr/bin/plutil -lint "$PROJECT_ROOT/SteamPackControl.entitlements" >/dev/null

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
verify_signed_bundle \
    "$CONTROL_EXTENSION" \
    "$PROJECT_ROOT/SteamPackControl.entitlements" \
    "$WORK_DIR" \
    "control-extension"
verify_signed_bundle \
    "$APP" \
    "$PROJECT_ROOT/SteamPack.entitlements" \
    "$WORK_DIR" \
    "app"
codesign --verify --deep --strict --verbose=2 "$APP"

APP_TEAM=$(signed_team_identifier "$APP")
EXTENSION_TEAM=$(signed_team_identifier "$CONTROL_EXTENSION")
[ -n "$APP_TEAM" ] && [ "$APP_TEAM" = "$EXTENSION_TEAM" ] || {
    echo "App and Control extension are not signed by the same team." >&2
    exit 1
}

BUILD_DIR="$STAGED_BUILD" \
DIST_DIR="$STAGED_DIST" \
APP_BUNDLE="$APP" \
DMG_NAME="$DMG_NAME" \
VOLUME_NAME="SteamPack" \
    "$PROJECT_ROOT/scripts/create-dmg.sh"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

# Apple notarizes the final DMG container and generates tickets for nested
# signed code as well as the disk image. We staple the distributed top-level
# DMG, then assess an unmodified app copied from that mounted DMG so a missing
# nested ticket or invalid inner signature fails the release.
xcrun notarytool submit \
    "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$NOTARY_RESULT"
NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT")
validate_notary_status "$NOTARY_STATUS"

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
STAPLED=1

hdiutil verify "$DMG"
IMAGE_VERIFIED=1
assess_release_dmg "$DMG"
DMG_GATEKEEPER=1

mkdir -p "$MOUNT_DIR" "$(dirname "$EXTRACTED_APP")"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=1
[ -d "$MOUNT_DIR/SteamPack.app" ] || {
    echo "SteamPack.app is missing from the mounted DMG." >&2
    exit 1
}
/usr/bin/ditto "$MOUNT_DIR/SteamPack.app" "$EXTRACTED_APP"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
assess_release_app "$EXTRACTED_APP"
APP_GATEKEEPER=1

hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

write_release_checksum \
    "$DMG" \
    "$CHECKSUM" \
    "$NOTARY_STATUS" \
    "$STAPLED" \
    "$IMAGE_VERIFIED" \
    "$DMG_GATEKEEPER" \
    "$APP_GATEKEEPER"
publish_release_pair "$DMG" "$CHECKSUM" "$FINAL_DMG" "$FINAL_CHECKSUM"

echo "Notarized release: $FINAL_DMG"
echo "SHA-256: $FINAL_CHECKSUM"
