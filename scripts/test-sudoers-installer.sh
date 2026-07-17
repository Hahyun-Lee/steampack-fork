#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-sudoers.sh"
TEMPLATE="$ROOT/scripts/steampack-pmset-sudoers"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT

/usr/bin/sed 's/__UID__/501/g' "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null

EXPECTED='#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0'
if ! /usr/bin/grep -Fxq "$EXPECTED" "$TMP"; then
    echo "not ok - rendered sudoers rule is not numeric-UID scoped"
    exit 1
fi

if ! /usr/bin/grep -Fq 'SUDOERS_PATH="/etc/sudoers.d/steampack-pmset-$USER_ID"' "$INSTALLER"; then
    echo "not ok - installer destination is not numeric-UID scoped"
    exit 1
fi

if /usr/bin/grep -Eq '"\$TMP"[[:space:]]+/etc/sudoers\.d/steampack-pmset([[:space:]]|$)' "$INSTALLER"; then
    echo "not ok - installer still writes the legacy shared destination"
    exit 1
fi

if ! /usr/bin/grep -Fq 'LEGACY_APP_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq 'LEGACY_HELPER_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '"$LEGACY_APP_HASH" "$LEGACY_HELPER_HASH"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/usr/bin/shasum -a 256 "$3"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/usr/bin/cut -d " " -f 1' "$INSTALLER"; then
    echo "not ok - exact legacy hashes are not both checked before cleanup"
    exit 1
fi

if ! /usr/bin/grep -Fq '/bin/rm -f "$3"' "$INSTALLER"; then
    echo "not ok - exact-match legacy cleanup is missing"
    exit 1
fi

for REQUIRED in \
    'ROOT_TMP="/etc/sudoers.d/.steampack-pmset-$USER_ID-' \
    '/usr/bin/cmp -s - "$2"' \
    '/usr/sbin/visudo -cf "$2"' \
    '/bin/mv -f "$2" "$4"'; do
    if ! /usr/bin/grep -Fq "$REQUIRED" "$INSTALLER"; then
        echo "not ok - root-owned validate-and-move install gate is incomplete"
        exit 1
    fi
done

echo "6 tests passed; 0 failed"
