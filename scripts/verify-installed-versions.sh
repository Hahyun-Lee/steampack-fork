#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-preflight.sh
source "$PROJECT_ROOT/scripts/release-preflight.sh"

APP="${1:-/Applications/SteamPack.app}"
CANDIDATE="${2:-}"
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    release_error "run installed verification as the logged-in user, not root"
    exit 2
fi
[ -d "$APP" ] || release_error "installed app is missing: $APP"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
APP_PLIST="$APP/Contents/Info.plist"
EXTENSION="$APP/Contents/PlugIns/SteamPackControl.appex"
EXTENSION_PLIST="$EXTENSION/Contents/Info.plist"
EXPECTED_VERSION="$(project_setting "$PROJECT_ROOT/project.yml" MARKETING_VERSION)"
EXPECTED_BUILD="$(project_setting "$PROJECT_ROOT/project.yml" CURRENT_PROJECT_VERSION)"
EXPECTED_APP_ID="com.steampack.app"
EXPECTED_EXTENSION_ID="com.steampack.app.control"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
PLUGIN_KIT_BIN="${PLUGIN_KIT_BIN:-/usr/bin/pluginkit}"
LIPO_BIN="${LIPO_BIN:-lipo}"

[ -f "$APP_PLIST" ] || release_error "installed app plist is missing: $APP_PLIST"
[ -f "$EXTENSION_PLIST" ] || release_error "installed Control extension plist is missing: $EXTENSION_PLIST"

APP_VERSION="$(plist_value "$APP_PLIST" CFBundleShortVersionString)"
APP_BUILD="$(plist_value "$APP_PLIST" CFBundleVersion)"
EXTENSION_VERSION="$(plist_value "$EXTENSION_PLIST" CFBundleShortVersionString)"
EXTENSION_BUILD="$(plist_value "$EXTENSION_PLIST" CFBundleVersion)"
APP_ID="$(plist_value "$APP_PLIST" CFBundleIdentifier)"
EXTENSION_ID="$(plist_value "$EXTENSION_PLIST" CFBundleIdentifier)"

validate_bundle_versions \
    "$APP_VERSION" "$APP_BUILD" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "installed app"
validate_bundle_versions \
    "$EXTENSION_VERSION" "$EXTENSION_BUILD" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "installed Control extension"
validate_bundle_identifier "$APP_ID" "$EXPECTED_APP_ID" "installed app"
validate_bundle_identifier \
    "$EXTENSION_ID" "$EXPECTED_EXTENSION_ID" \
    "installed Control extension"

"$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP"
"$CODESIGN_BIN" --verify --strict --verbose=2 "$EXTENSION"
validate_bundle_identifier \
    "$(signed_bundle_identifier "$APP")" "$EXPECTED_APP_ID" \
    "signed app"
validate_bundle_identifier \
    "$(signed_bundle_identifier "$EXTENSION")" "$EXPECTED_EXTENSION_ID" \
    "signed Control extension"

APP_TEAM="$(signed_team_identifier "$APP")"
EXTENSION_TEAM="$(signed_team_identifier "$EXTENSION")"
validate_signing_teams "$APP_TEAM" "$EXTENSION_TEAM" "$ALLOW_ADHOC_SIGNING"
validate_universal_arches "$("$LIPO_BIN" -archs "$APP/Contents/MacOS/SteamPack")"
validate_universal_arches "$("$LIPO_BIN" -archs "$EXTENSION/Contents/MacOS/SteamPackControl")"

EXTENSION_ENTITLEMENTS="$("$CODESIGN_BIN" -d --entitlements :- "$EXTENSION" 2>/dev/null \
    | /usr/bin/plutil -p -)"
validate_sandbox_entitlement "$EXTENSION_ENTITLEMENTS"

if ! REGISTRY_OUTPUT="$("$PLUGIN_KIT_BIN" -m -A -D -vv -i "$EXPECTED_EXTENSION_ID" 2>&1)"; then
    release_error "PlugInKit query failed: $REGISTRY_OUTPUT"
    exit 1
fi
REGISTERED_PATHS="$(printf '%s\n' "$REGISTRY_OUTPUT" \
    | awk -F' = ' '/^[[:space:]]*Path = /{print $2}')"
validate_registered_extension_path "$REGISTERED_PATHS" "$EXTENSION"

if [ -n "$CANDIDATE" ]; then
    [ -d "$CANDIDATE" ] || release_error "source candidate is missing: $CANDIDATE"
    CANDIDATE="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
    CANDIDATE_EXTENSION="$CANDIDATE/Contents/PlugIns/SteamPackControl.appex"
    "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$CANDIDATE"
    validate_universal_arches "$("$LIPO_BIN" -archs "$CANDIDATE/Contents/MacOS/SteamPack")"
    validate_universal_arches \
        "$("$LIPO_BIN" -archs "$CANDIDATE_EXTENSION/Contents/MacOS/SteamPackControl")"
    for arch in arm64 x86_64; do
        [ "$(signed_cdhash_for_arch "$APP" "$arch")" = \
          "$(signed_cdhash_for_arch "$CANDIDATE" "$arch")" ] || {
            release_error "installed app $arch CDHash differs from the source candidate"
            exit 1
        }
        [ "$(signed_cdhash_for_arch "$EXTENSION" "$arch")" = \
          "$(signed_cdhash_for_arch "$CANDIDATE_EXTENSION" "$arch")" ] || {
            release_error "installed Control extension $arch CDHash differs from the source candidate"
            exit 1
        }
    done
fi

SIGNING_LABEL="$APP_TEAM"
[ -n "$SIGNING_LABEL" ] || SIGNING_LABEL="ad-hoc"
printf 'Installed app and Control extension: %s (%s), signing %s, registered %s\n' \
    "$APP_VERSION" "$APP_BUILD" "$SIGNING_LABEL" "$EXTENSION"
if [ -n "$CANDIDATE" ]; then
    printf 'Installed code matches source candidate CDHashes: %s\n' "$CANDIDATE"
fi
