#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-preflight.sh
source "$PROJECT_ROOT/scripts/release-preflight.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/steampack-release-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok - %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok - %s\n' "$1" >&2
}

expect_success() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name"
    fi
}

expect_failure() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$name"
    else
        pass "$name"
    fi
}

expect_success "stable tag matches app version" validate_release_tag v1.4.0 1.4.0
expect_success "release-candidate tag matches app version" validate_release_tag v1.4.0-rc.1 1.4.0
expect_success "preview tag matches app version" validate_release_tag v1.4.0-preview.3 1.4.0
expect_failure "tag rejects a different app version" validate_release_tag v1.4.1 1.4.0
expect_failure "tag rejects an unbounded suffix" validate_release_tag v1.4.0-test 1.4.0

expect_success "positive build number is accepted" validate_build_number 7
expect_failure "zero build number is rejected" validate_build_number 0
expect_failure "non-numeric build number is rejected" validate_build_number build7
FAKE_IDENTITIES='  1) 0123456789ABCDEF "Developer ID Application: Release Test (TEAM123456)"'
expect_success \
    "Developer ID Application identity is accepted" \
    validate_developer_id_identity "$FAKE_IDENTITIES" "Release Test"
expect_failure \
    "non-Developer-ID identity is rejected" \
    validate_developer_id_identity '  1) 0123 "Apple Development: Release Test"' "Release Test"
expect_success "source version and build agree" validate_source_versions 1.4.0 9 1.4.0 9
expect_failure "source version mismatch is rejected" validate_source_versions 1.4.0 9 1.4.1 9
expect_success \
    "embedded extension version and build match the app" \
    validate_bundle_versions 1.4.0 9 1.4.0 9 "Control extension"
expect_failure \
    "stale embedded extension build is rejected" \
    validate_bundle_versions 1.4.0 8 1.4.0 9 "Control extension"
expect_success \
    "app bundle identifier is exact" \
    validate_bundle_identifier com.steampack.app com.steampack.app "app"
expect_failure \
    "bare linker identifier is rejected" \
    validate_bundle_identifier SteamPack com.steampack.app "app"
expect_success \
    "app and extension use one signing team" \
    validate_signing_teams TEAM123456 TEAM123456 0
expect_failure \
    "different signing teams are rejected" \
    validate_signing_teams TEAM123456 TEAM654321 0
expect_failure \
    "missing signing teams are rejected by default" \
    validate_signing_teams "" "" 0
expect_success \
    "explicit local test mode accepts proper ad-hoc signing" \
    validate_signing_teams "" "" 1
expect_success \
    "Control extension sandbox entitlement is required" \
    validate_sandbox_entitlement '{ "com.apple.security.app-sandbox" => true }'
expect_failure \
    "missing Control extension sandbox entitlement is rejected" \
    validate_sandbox_entitlement '{}'
expect_success \
    "one installed Control extension path is accepted" \
    validate_registered_extension_path \
    /Applications/SteamPack.app/Contents/PlugIns/SteamPackControl.appex \
    /Applications/SteamPack.app/Contents/PlugIns/SteamPackControl.appex
expect_failure \
    "a stale temporary Control extension path is rejected" \
    validate_registered_extension_path \
    /private/tmp/SteamPackControl.appex \
    /Applications/SteamPack.app/Contents/PlugIns/SteamPackControl.appex
expect_failure \
    "multiple registered Control extensions are rejected" \
    validate_registered_extension_path \
    $'/private/tmp/SteamPackControl.appex\n/Applications/SteamPack.app/Contents/PlugIns/SteamPackControl.appex' \
    /Applications/SteamPack.app/Contents/PlugIns/SteamPackControl.appex

expect_success "clean status is accepted" validate_clean_status ""
expect_failure "dirty status is rejected" validate_clean_status " M README.md"
expect_success "matching release commit is accepted" validate_commit_match abc123 abc123
expect_failure "wrong release commit is rejected" validate_commit_match abc123 def456

GIT_FIXTURE="$TEST_DIR/repository"
git init -q -b main "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" config user.name "Release Test"
git -C "$GIT_FIXTURE" config user.email "release-test@example.invalid"
git -C "$GIT_FIXTURE" config commit.gpgsign false
printf 'initial\n' > "$GIT_FIXTURE/tracked.txt"
git -C "$GIT_FIXTURE" add tracked.txt
git -C "$GIT_FIXTURE" commit -q -m initial
git -C "$GIT_FIXTURE" tag v1.4.0
git -C "$GIT_FIXTURE" update-ref refs/remotes/origin/main HEAD
expect_success \
    "repository preflight accepts clean tagged canonical HEAD" \
    require_release_repository_state "$GIT_FIXTURE" origin/main v1.4.0 1.4.0
expect_failure \
    "repository preflight rejects a missing base ref" \
    require_release_repository_state "$GIT_FIXTURE" missing/main v1.4.0 1.4.0
printf 'dirty\n' > "$GIT_FIXTURE/untracked.txt"
expect_failure \
    "repository preflight rejects an untracked file" \
    require_release_repository_state "$GIT_FIXTURE" origin/main v1.4.0 1.4.0
rm -f "$GIT_FIXTURE/untracked.txt"
printf 'second\n' >> "$GIT_FIXTURE/tracked.txt"
git -C "$GIT_FIXTURE" add tracked.txt
git -C "$GIT_FIXTURE" commit -q -m second
git -C "$GIT_FIXTURE" update-ref refs/remotes/origin/main HEAD
expect_failure \
    "repository preflight rejects a tag that is not at HEAD" \
    require_release_repository_state "$GIT_FIXTURE" origin/main v1.4.0 1.4.0

expect_success "universal architecture set is accepted" validate_universal_arches "arm64 x86_64"
expect_success "universal architecture order is irrelevant" validate_universal_arches "x86_64 arm64"
expect_failure "arm64-only artifact is rejected" validate_universal_arches "arm64"
expect_failure "unknown extra architecture is rejected" validate_universal_arches "arm64 x86_64 i386"

set +e
CREDENTIAL_OUTPUT=$(env \
    -u DEVELOPER_ID_APPLICATION \
    -u NOTARY_PROFILE \
    -u RELEASE_TAG \
    "$PROJECT_ROOT/scripts/release.sh" 2>&1)
CREDENTIAL_STATUS=$?
set -e
if [ "$CREDENTIAL_STATUS" -eq 2 ] && \
   printf '%s\n' "$CREDENTIAL_OUTPUT" | grep -q 'Developer ID signed and notarized'; then
    pass "missing credentials exit 2 before repository or build work"
else
    fail "missing credentials exit 2 before repository or build work"
fi

SPCTL_LOG="$TEST_DIR/spctl.log"
FAKE_SPCTL="$TEST_DIR/spctl"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "%s\n" "$*" >> "$SPCTL_LOG"' \
    'exit 0' > "$FAKE_SPCTL"
chmod +x "$FAKE_SPCTL"
export SPCTL_LOG
export SPCTL_BIN="$FAKE_SPCTL"

expect_success "DMG Gatekeeper wrapper succeeds" assess_release_dmg "$TEST_DIR/SteamPack.dmg"
expect_success "extracted-app Gatekeeper wrapper succeeds" assess_release_app "$TEST_DIR/SteamPack.app"
if grep -q -- '--assess --type open --context context:primary-signature' "$SPCTL_LOG" && \
   grep -q -- "--assess --type execute --verbose=4 $TEST_DIR/SteamPack.app" "$SPCTL_LOG"; then
    pass "Gatekeeper uses open for DMG and execute for extracted app"
else
    fail "Gatekeeper uses open for DMG and execute for extracted app"
fi

ARTIFACT="$TEST_DIR/SteamPack-1.4.0-rc.1.dmg"
CHECKSUM="$ARTIFACT.sha256"
printf 'final stapled disk image\n' > "$ARTIFACT"

expect_failure \
    "checksum rejects pending notarization" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Pending 1 1 1 1
[ ! -e "$CHECKSUM" ] && pass "pending notarization leaves no checksum" || fail "pending notarization leaves no checksum"

expect_failure \
    "checksum rejects missing staple validation" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Accepted 0 1 1 1
[ ! -e "$CHECKSUM" ] && pass "missing staple leaves no checksum" || fail "missing staple leaves no checksum"

expect_failure \
    "checksum rejects failed disk-image verification" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Accepted 1 0 1 1
[ ! -e "$CHECKSUM" ] && pass "failed image verification leaves no checksum" || fail "failed image verification leaves no checksum"

expect_failure \
    "checksum rejects missing DMG Gatekeeper" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Accepted 1 1 0 1
[ ! -e "$CHECKSUM" ] && pass "failed DMG Gatekeeper leaves no checksum" || fail "failed DMG Gatekeeper leaves no checksum"

expect_failure \
    "checksum rejects missing extracted-app Gatekeeper" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Accepted 1 1 1 0
[ ! -e "$CHECKSUM" ] && pass "failed app Gatekeeper leaves no checksum" || fail "failed app Gatekeeper leaves no checksum"

expect_success \
    "checksum is written after every release gate" \
    write_release_checksum "$ARTIFACT" "$CHECKSUM" Accepted 1 1 1 1
EXPECTED_DIGEST=$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')
if grep -q "^${EXPECTED_DIGEST}  $(basename "$ARTIFACT")$" "$CHECKSUM"; then
    pass "checksum covers the final named DMG"
else
    fail "checksum covers the final named DMG"
fi

PUBLISH_DIR="$TEST_DIR/published"
FINAL_ARTIFACT="$PUBLISH_DIR/$(basename "$ARTIFACT")"
FINAL_CHECKSUM="$FINAL_ARTIFACT.sha256"
expect_success \
    "verified artifact pair publishes only at the final step" \
    publish_release_pair "$ARTIFACT" "$CHECKSUM" "$FINAL_ARTIFACT" "$FINAL_CHECKSUM"
if cmp -s "$ARTIFACT" "$FINAL_ARTIFACT" && cmp -s "$CHECKSUM" "$FINAL_CHECKSUM"; then
    pass "published artifact pair matches staged files"
else
    fail "published artifact pair matches staged files"
fi
printf 'prior valid artifact\n' > "$FINAL_ARTIFACT"
expect_failure \
    "pair publishing refuses to overwrite a prior artifact" \
    publish_release_pair "$ARTIFACT" "$CHECKSUM" "$FINAL_ARTIFACT" "$FINAL_CHECKSUM"
if grep -q '^prior valid artifact$' "$FINAL_ARTIFACT"; then
    pass "failed republish preserves the prior artifact"
else
    fail "failed republish preserves the prior artifact"
fi

printf '%s tests passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
