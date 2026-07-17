#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/build/adhoc}"
OWN_DERIVED_DATA=0

if [ -z "${DERIVED_DATA:-}" ]; then
    DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/steampack-local-adhoc.XXXXXX")"
    OWN_DERIVED_DATA=1
else
    mkdir -p "$DERIVED_DATA"
fi
mkdir -p "$OUTPUT_DIR"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd -P)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
APP="$OUTPUT_DIR/SteamPack.app"
EXTENSION="$APP/Contents/PlugIns/SteamPackControl.appex"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/SteamPack.app"
BUILT_EXTENSION="$BUILT_APP/Contents/PlugIns/SteamPackControl.appex"
PLUGIN_KIT_BIN="${PLUGIN_KIT_BIN:-/usr/bin/pluginkit}"

# shellcheck source=scripts/release-preflight.sh
source "$PROJECT_ROOT/scripts/release-preflight.sh"

EXPECTED_VERSION="$(project_setting "$PROJECT_ROOT/project.yml" MARKETING_VERSION)"
EXPECTED_BUILD="$(project_setting "$PROJECT_ROOT/project.yml" CURRENT_PROJECT_VERSION)"

case "$APP" in
    "$PROJECT_ROOT"/build/*/SteamPack.app|/private/tmp/*/SteamPack.app|/private/var/folders/*/SteamPack.app)
        ;;
    *)
        release_error "local output must stay under project build/ or a temporary directory: $APP"
        exit 2
        ;;
esac

registered_extension_paths() {
    "$PLUGIN_KIT_BIN" -m -A -D -vv -i com.steampack.app.control \
        | awk -F' = ' '/^[[:space:]]*Path = /{print $2}'
}

is_owned_build_path() {
    case "$1" in
        "$DERIVED_DATA"/*|"$OUTPUT_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    local status=$?
    local path
    local remaining
    trap - EXIT
    set +e

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_owned_build_path "$path"; then
            "$PLUGIN_KIT_BIN" -r "$path" >/dev/null 2>&1
        fi
    done < <(registered_extension_paths 2>/dev/null)

    remaining="$(registered_extension_paths 2>/dev/null)"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_owned_build_path "$path"; then
            release_error "temporary Control extension remains registered: $path"
            status=1
        fi
    done <<< "$remaining"

    if [ "$OWN_DERIVED_DATA" -eq 1 ]; then
        /bin/rm -rf -- "$DERIVED_DATA"
    fi
    exit "$status"
}
trap cleanup EXIT

for command_name in xcodegen xcodebuild codesign lipo "$PLUGIN_KIT_BIN"; do
    command -v "$command_name" >/dev/null || {
        release_error "required local-build command is missing: $command_name"
        exit 2
    }
done

cd "$PROJECT_ROOT"
xcodegen generate
xcodebuild \
    -quiet \
    -project SteamPack.xcodeproj \
    -scheme SteamPack \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    ONLY_ACTIVE_ARCH=NO \
    'ARCHS=arm64 x86_64' \
    build

if [ -e "$APP" ]; then
    /bin/rm -rf -- "$APP"
fi
/usr/bin/ditto \
    "$BUILT_APP" \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
validate_bundle_versions \
    "$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)" \
    "$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "local ad-hoc app"
validate_bundle_versions \
    "$(plist_value "$EXTENSION/Contents/Info.plist" CFBundleShortVersionString)" \
    "$(plist_value "$EXTENSION/Contents/Info.plist" CFBundleVersion)" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "local ad-hoc Control extension"
validate_bundle_identifier \
    "$(signed_bundle_identifier "$APP")" \
    com.steampack.app \
    "local ad-hoc app"
validate_bundle_identifier \
    "$(signed_bundle_identifier "$EXTENSION")" \
    com.steampack.app.control \
    "local ad-hoc Control extension"
validate_signing_teams \
    "$(signed_team_identifier "$APP")" \
    "$(signed_team_identifier "$EXTENSION")" \
    1
validate_sandbox_entitlement "$(codesign -d --entitlements :- "$EXTENSION" 2>/dev/null \
    | /usr/bin/plutil -p -)"
validate_universal_arches "$(lipo -archs "$APP/Contents/MacOS/SteamPack")"
validate_universal_arches "$(lipo -archs "$EXTENSION/Contents/MacOS/SteamPackControl")"

printf 'Local ad-hoc test build: %s\n' "$APP"
printf '%s\n' 'This build is for local Control Center E2E only, not distribution.'
printf '%s\n' 'After installation, verify with:'
printf '  ALLOW_ADHOC_SIGNING=1 bash scripts/verify-installed-versions.sh /Applications/SteamPack.app %q\n' "$APP"
