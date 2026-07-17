#!/bin/bash

# Pure validation helpers and release verification functions. This file is
# sourced by release.sh and by the deterministic shell tests; it intentionally
# performs no work when sourced.

release_error() {
    printf 'release preflight: %s\n' "$*" >&2
    return 1
}

validate_clean_status() {
    local status="${1:-}"
    [ -z "$status" ] || release_error "working tree is not clean"
}

validate_commit_match() {
    local head_commit="${1:-}"
    local base_commit="${2:-}"

    [ -n "$head_commit" ] || return 1
    [ -n "$base_commit" ] || return 1
    [ "$head_commit" = "$base_commit" ] || \
        release_error "HEAD $head_commit does not match release base $base_commit"
}

validate_release_tag() {
    local tag="${1:-}"
    local version="${2:-}"
    local tagged_version

    if ! [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-(alpha|beta|rc|preview)\.[0-9]+)?$ ]]; then
        release_error "tag '$tag' must be vMAJOR.MINOR.PATCH or an alpha/beta/rc/preview tag"
        return 1
    fi

    tagged_version="${BASH_REMATCH[1]}"
    [ "$tagged_version" = "$version" ] || \
        release_error "tag '$tag' does not match app version '$version'"
}

validate_build_number() {
    local build="${1:-}"
    [[ "$build" =~ ^[1-9][0-9]*$ ]] || \
        release_error "build number '$build' must be a positive integer"
}

validate_developer_id_identity() {
    local identities="${1:-}"
    local selector="${2:-}"
    local matching_line

    [ -n "$selector" ] || { release_error "Developer ID identity selector is empty"; return 1; }
    matching_line=$(printf '%s\n' "$identities" | grep -F -- "$selector" | head -n 1)
    [ -n "$matching_line" ] || {
        release_error "Developer ID identity is not available: $selector"
        return 1
    }
    case "$matching_line" in
        *'"Developer ID Application:'*'"'*) return 0 ;;
        *) release_error "selected identity is not a Developer ID Application certificate"; return 1 ;;
    esac
}

validate_source_versions() {
    local plist_version="${1:-}"
    local plist_build="${2:-}"
    local project_version="${3:-}"
    local project_build="${4:-}"

    [ "$plist_version" = "$project_version" ] || {
        release_error "AppInfo.plist version '$plist_version' differs from project.yml '$project_version'"
        return 1
    }
    [ "$plist_build" = "$project_build" ] || {
        release_error "AppInfo.plist build '$plist_build' differs from project.yml '$project_build'"
        return 1
    }
    validate_build_number "$plist_build"
}

validate_bundle_versions() {
    local actual_version="${1:-}"
    local actual_build="${2:-}"
    local expected_version="${3:-}"
    local expected_build="${4:-}"
    local label="${5:-bundle}"

    [ "$actual_version" = "$expected_version" ] || {
        release_error "$label version '$actual_version' differs from '$expected_version'"
        return 1
    }
    [ "$actual_build" = "$expected_build" ] || {
        release_error "$label build '$actual_build' differs from '$expected_build'"
        return 1
    }
}

validate_bundle_identifier() {
    local actual="${1:-}"
    local expected="${2:-}"
    local label="${3:-bundle}"

    [ "$actual" = "$expected" ] || {
        release_error "$label identifier '$actual' differs from '$expected'"
        return 1
    }
}

validate_signing_teams() {
    local app_team="${1:-}"
    local extension_team="${2:-}"
    local allow_adhoc="${3:-0}"

    if [ -n "$app_team" ] || [ -n "$extension_team" ]; then
        [ -n "$app_team" ] && [ "$app_team" = "$extension_team" ] || {
            release_error "app and Control extension must have the same nonempty TeamIdentifier"
            return 1
        }
        return 0
    fi

    [ "$allow_adhoc" = "1" ] || {
        release_error "app and Control extension do not have a TeamIdentifier"
        return 1
    }
}

validate_sandbox_entitlement() {
    local entitlements="${1:-}"

    printf '%s\n' "$entitlements" \
        | grep -q '"com.apple.security.app-sandbox" => true' || {
        release_error "Control extension is missing the app-sandbox entitlement"
        return 1
    }
}

validate_registered_extension_path() {
    local registered_paths="${1:-}"
    local expected_path="${2:-}"
    local count

    count=$(printf '%s\n' "$registered_paths" | awk 'NF { count += 1 } END { print count + 0 }')
    [ "$count" -eq 1 ] || {
        release_error "expected one registered Control extension, found $count"
        return 1
    }
    [ "$registered_paths" = "$expected_path" ] || {
        release_error "registered Control extension '$registered_paths' differs from '$expected_path'"
        return 1
    }
}

validate_universal_arches() {
    local arches="${1:-}"
    local arch
    local count=0
    local has_arm64=0
    local has_x86_64=0

    for arch in $arches; do
        count=$((count + 1))
        case "$arch" in
            arm64) has_arm64=1 ;;
            x86_64) has_x86_64=1 ;;
            *) release_error "unexpected architecture '$arch' in '$arches'"; return 1 ;;
        esac
    done

    [ "$count" -eq 2 ] && [ "$has_arm64" -eq 1 ] && [ "$has_x86_64" -eq 1 ] || \
        release_error "expected exactly arm64 and x86_64, found '$arches'"
}

validate_notary_status() {
    local status="${1:-}"
    [ "$status" = "Accepted" ] || \
        release_error "Apple notarization status is '$status', not 'Accepted'"
}

validate_checksum_ready() {
    local notary_status="${1:-}"
    local stapled="${2:-0}"
    local image_verified="${3:-0}"
    local dmg_gatekeeper="${4:-0}"
    local app_gatekeeper="${5:-0}"

    validate_notary_status "$notary_status" || return 1
    [ "$stapled" = "1" ] || { release_error "notarization ticket is not stapled and validated"; return 1; }
    [ "$image_verified" = "1" ] || { release_error "disk image has not passed hdiutil verification"; return 1; }
    [ "$dmg_gatekeeper" = "1" ] || { release_error "disk image has not passed Gatekeeper"; return 1; }
    [ "$app_gatekeeper" = "1" ] || { release_error "mounted and copied app has not passed Gatekeeper"; return 1; }
}

write_release_checksum() {
    local artifact="$1"
    local checksum="$2"
    local notary_status="$3"
    local stapled="$4"
    local image_verified="$5"
    local dmg_gatekeeper="$6"
    local app_gatekeeper="$7"
    local digest
    local temporary_checksum="${checksum}.tmp.$$"
    local shasum_bin="${SHASUM_BIN:-shasum}"

    # Never leave an earlier checksum beside an artifact whose final gates have
    # not passed in this invocation.
    rm -f "$checksum" "$temporary_checksum"
    validate_checksum_ready \
        "$notary_status" \
        "$stapled" \
        "$image_verified" \
        "$dmg_gatekeeper" \
        "$app_gatekeeper" || return 1
    [ -f "$artifact" ] || { release_error "release artifact does not exist: $artifact"; return 1; }

    digest=$("$shasum_bin" -a 256 "$artifact" | awk '{print $1}') || return 1
    [ -n "$digest" ] || { release_error "could not calculate SHA-256"; return 1; }

    if ! printf '%s  %s\n' "$digest" "$(basename "$artifact")" > "$temporary_checksum"; then
        rm -f "$temporary_checksum"
        return 1
    fi
    mv "$temporary_checksum" "$checksum"
}

publish_release_pair() {
    local staged_artifact="$1"
    local staged_checksum="$2"
    local final_artifact="$3"
    local final_checksum="$4"
    local final_dir
    local artifact_candidate
    local checksum_candidate
    local expected_digest
    local copied_digest

    [ -f "$staged_artifact" ] || { release_error "staged artifact does not exist: $staged_artifact"; return 1; }
    [ -f "$staged_checksum" ] || { release_error "staged checksum does not exist: $staged_checksum"; return 1; }
    [ ! -e "$final_artifact" ] || { release_error "refusing to overwrite existing release: $final_artifact"; return 1; }
    [ ! -e "$final_checksum" ] || { release_error "refusing to overwrite existing checksum: $final_checksum"; return 1; }

    final_dir=$(dirname "$final_artifact")
    [ "$final_dir" = "$(dirname "$final_checksum")" ] || {
        release_error "artifact and checksum must be published to the same directory"
        return 1
    }
    mkdir -p "$final_dir"

    artifact_candidate="$final_dir/.$(basename "$final_artifact").new.$$"
    checksum_candidate="$final_dir/.$(basename "$final_checksum").new.$$"
    rm -f "$artifact_candidate" "$checksum_candidate"

    /usr/bin/ditto "$staged_artifact" "$artifact_candidate" || return 1
    /usr/bin/ditto "$staged_checksum" "$checksum_candidate" || {
        rm -f "$artifact_candidate" "$checksum_candidate"
        return 1
    }
    cmp -s "$staged_artifact" "$artifact_candidate" || {
        rm -f "$artifact_candidate" "$checksum_candidate"
        release_error "published artifact copy differs from staged artifact"
        return 1
    }
    cmp -s "$staged_checksum" "$checksum_candidate" || {
        rm -f "$artifact_candidate" "$checksum_candidate"
        release_error "published checksum copy differs from staged checksum"
        return 1
    }

    expected_digest=$(awk 'NR == 1 {print $1}' "$checksum_candidate")
    copied_digest=$(shasum -a 256 "$artifact_candidate" | awk '{print $1}')
    [ -n "$expected_digest" ] && [ "$expected_digest" = "$copied_digest" ] || {
        rm -f "$artifact_candidate" "$checksum_candidate"
        release_error "checksum does not match the copied release artifact"
        return 1
    }

    # The candidates are copied into final_dir so hard links are atomic and
    # create-or-fail. Unlike BSD mv, ln never overwrites a target created by a
    # concurrent release. Publish the checksum first and the DMG last, so an
    # interrupted pair publish cannot leave a public-looking DMG without its
    # checksum.
    if ! ln "$checksum_candidate" "$final_checksum"; then
        rm -f "$artifact_candidate" "$checksum_candidate"
        return 1
    fi
    if ! ln "$artifact_candidate" "$final_artifact"; then
        rm -f "$final_checksum" "$artifact_candidate"
        return 1
    fi
    rm -f "$artifact_candidate" "$checksum_candidate"
}

assess_release_dmg() {
    local dmg="$1"
    local spctl_bin="${SPCTL_BIN:-spctl}"

    "$spctl_bin" \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$dmg"
}

assess_release_app() {
    local app="$1"
    local spctl_bin="${SPCTL_BIN:-spctl}"

    "$spctl_bin" --assess --type execute --verbose=4 "$app"
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
}

project_setting() {
    local project_file="$1"
    local key="$2"
    awk -v key="$key" '
        $1 == key ":" {
            value = $2
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$project_file"
}

require_release_repository_state() {
    local project_root="$1"
    local release_base_ref="$2"
    local release_tag="$3"
    local app_version="$4"
    local status
    local head_commit
    local base_commit
    local tag_commit

    status=$(git -C "$project_root" status --porcelain=v1 --untracked-files=normal)
    validate_clean_status "$status" || return 1

    git -C "$project_root" rev-parse --verify --quiet "${release_base_ref}^{commit}" >/dev/null || {
        release_error "release base ref '$release_base_ref' does not exist; fetch it or set RELEASE_BASE_REF explicitly"
        return 1
    }
    head_commit=$(git -C "$project_root" rev-parse HEAD)
    base_commit=$(git -C "$project_root" rev-parse "${release_base_ref}^{commit}")
    validate_commit_match "$head_commit" "$base_commit" || return 1

    validate_release_tag "$release_tag" "$app_version" || return 1
    git -C "$project_root" rev-parse --verify --quiet "refs/tags/${release_tag}^{commit}" >/dev/null || {
        release_error "release tag '$release_tag' does not exist locally"
        return 1
    }
    tag_commit=$(git -C "$project_root" rev-parse "refs/tags/${release_tag}^{commit}")
    validate_commit_match "$head_commit" "$tag_commit" || {
        release_error "release tag '$release_tag' does not point to HEAD"
        return 1
    }
}

verify_plists_equivalent() {
    local expected="$1"
    local actual="$2"
    local expected_dump
    local actual_dump

    /usr/bin/plutil -lint "$expected" >/dev/null || return 1
    /usr/bin/plutil -lint "$actual" >/dev/null || return 1
    expected_dump=$(/usr/bin/plutil -p "$expected" | LC_ALL=C sort)
    actual_dump=$(/usr/bin/plutil -p "$actual" | LC_ALL=C sort)
    [ "$expected_dump" = "$actual_dump" ] || \
        release_error "signed entitlements differ from $expected"
}

verify_signed_bundle() {
    local bundle="$1"
    local expected_entitlements="$2"
    local work_dir="$3"
    local label="$4"
    local expected_identifier="${5:-}"
    local metadata_file="$work_dir/${label}.codesign.txt"
    local actual_entitlements="$work_dir/${label}.entitlements.plist"
    local entitlement_errors="$work_dir/${label}.entitlements.stderr"

    codesign --verify --strict --verbose=2 "$bundle"
    codesign -dv --verbose=4 "$bundle" > /dev/null 2> "$metadata_file"
    if [ -n "$expected_identifier" ]; then
        grep -Fxq "Identifier=$expected_identifier" "$metadata_file" || {
            release_error "$label signed identifier differs from $expected_identifier"
            return 1
        }
    fi
    grep -q '^Authority=Developer ID Application:' "$metadata_file" || {
        release_error "$label is not signed by Developer ID Application"
        return 1
    }
    grep -Eq '^CodeDirectory .*flags=.*runtime' "$metadata_file" || {
        release_error "$label does not have hardened runtime"
        return 1
    }
    grep -q '^Timestamp=' "$metadata_file" || {
        release_error "$label does not have a secure timestamp"
        return 1
    }
    grep -Eq '^TeamIdentifier=[A-Z0-9]+$' "$metadata_file" || {
        release_error "$label does not have a TeamIdentifier"
        return 1
    }

    if ! codesign -d --entitlements - "$bundle" > "$actual_entitlements" 2> "$entitlement_errors"; then
        release_error "could not extract $label entitlements"
        return 1
    fi
    if grep -qi 'invalid entitlements' "$entitlement_errors"; then
        release_error "$label contains an invalid entitlements blob"
        return 1
    fi
    verify_plists_equivalent "$expected_entitlements" "$actual_entitlements"
}

signed_team_identifier() {
    local bundle="$1"
    local codesign_bin="${CODESIGN_BIN:-codesign}"
    "$codesign_bin" -dv --verbose=4 "$bundle" 2>&1 | awk -F= '
        /^TeamIdentifier=/ {
            if ($2 != "not set") print $2
            exit
        }
    '
}

signed_bundle_identifier() {
    local bundle="$1"
    local codesign_bin="${CODESIGN_BIN:-codesign}"
    "$codesign_bin" -dv --verbose=4 "$bundle" 2>&1 \
        | awk -F= '/^Identifier=/{print $2; exit}'
}

signed_cdhash_for_arch() {
    local bundle="$1"
    local arch="$2"
    local codesign_bin="${CODESIGN_BIN:-codesign}"
    "$codesign_bin" -d --arch "$arch" --verbose=4 "$bundle" 2>&1 \
        | awk -F= '/^CDHash=/{print $2; exit}'
}
