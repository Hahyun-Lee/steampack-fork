#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-preflight.sh
source "$PROJECT_ROOT/scripts/release-preflight.sh"

APP="${1:-/Applications/SteamPack.app}"
APP_PLIST="$APP/Contents/Info.plist"
EXTENSION_PLIST="$APP/Contents/PlugIns/SteamPackControl.appex/Contents/Info.plist"
EXPECTED_VERSION="$(project_setting "$PROJECT_ROOT/project.yml" MARKETING_VERSION)"
EXPECTED_BUILD="$(project_setting "$PROJECT_ROOT/project.yml" CURRENT_PROJECT_VERSION)"

[ -f "$APP_PLIST" ] || release_error "installed app plist is missing: $APP_PLIST"
[ -f "$EXTENSION_PLIST" ] || release_error "installed Control extension plist is missing: $EXTENSION_PLIST"

APP_VERSION="$(plist_value "$APP_PLIST" CFBundleShortVersionString)"
APP_BUILD="$(plist_value "$APP_PLIST" CFBundleVersion)"
EXTENSION_VERSION="$(plist_value "$EXTENSION_PLIST" CFBundleShortVersionString)"
EXTENSION_BUILD="$(plist_value "$EXTENSION_PLIST" CFBundleVersion)"

validate_bundle_versions \
    "$APP_VERSION" "$APP_BUILD" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "installed app"
validate_bundle_versions \
    "$EXTENSION_VERSION" "$EXTENSION_BUILD" \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "installed Control extension"

printf 'Installed app and Control extension: %s (%s)\n' \
    "$APP_VERSION" "$APP_BUILD"
