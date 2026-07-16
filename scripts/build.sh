#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/tmp/steampack-build}"
OUTPUT_DIR="$PROJECT_ROOT/build"
TEAM="${DEVELOPMENT_TEAM:-}"

if [ -z "$TEAM" ]; then
    echo "DEVELOPMENT_TEAM is required for the macOS Control Center extension."
    echo "Example: DEVELOPMENT_TEAM=ABCDE12345 scripts/build.sh"
    exit 2
fi

command -v xcodegen >/dev/null || {
    echo "xcodegen is required: brew install xcodegen"
    exit 2
}

cd "$PROJECT_ROOT"
xcodegen generate

xcodebuild \
    -project SteamPack.xcodeproj \
    -scheme SteamPack \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" \
    build

mkdir -p "$OUTPUT_DIR"
/usr/bin/ditto \
    "$DERIVED_DATA/Build/Products/Release/SteamPack.app" \
    "$OUTPUT_DIR/SteamPack.app"

codesign --verify --deep --strict --verbose=2 "$OUTPUT_DIR/SteamPack.app"
echo "Built: $OUTPUT_DIR/SteamPack.app"
