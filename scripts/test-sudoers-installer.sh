#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-sudoers.sh"
TEMPLATE="$ROOT/scripts/steampack-pmset-sudoers"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT

/usr/bin/sed 's/__UID__/501/g' "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null

EXPECTED='#501 ALL=(root) TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 1, TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 0'
if ! /usr/bin/grep -Fxq "$EXPECTED" "$TMP"; then
    echo "not ok - rendered sudoers rule is not UID-scoped with two exact command timeouts"
    exit 1
fi

TIMEOUT_COUNT="$(/usr/bin/grep -o 'TIMEOUT=1s' "$TMP" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$TIMEOUT_COUNT" != "2" ]] || /usr/bin/grep -Fq 'Defaults!' "$TMP"; then
    echo "not ok - timeout must be repeated on each command without a broad Defaults rule"
    exit 1
fi

if ! /usr/bin/grep -Fq 'SUDOERS_PATH="/etc/sudoers.d/steampack-pmset-v2-$USER_ID"' "$INSTALLER"; then
    echo "not ok - installer destination is not versioned and numeric-UID scoped"
    exit 1
fi

if ! /usr/bin/grep -Fq 'OLD_SCOPED_PATH="/etc/sudoers.d/steampack-pmset-$USER_ID"' "$INSTALLER"; then
    echo "not ok - v1 account-scoped migration path is missing"
    exit 1
fi

if /usr/bin/grep -Eq '"\$TMP"[[:space:]]+/etc/sudoers\.d/steampack-pmset([[:space:]]|$)' "$INSTALLER"; then
    echo "not ok - installer still writes the legacy shared destination"
    exit 1
fi

if ! /usr/bin/grep -Fq 'LEGACY_APP_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq 'LEGACY_HELPER_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '"$LEGACY_APP_HASH" "$LEGACY_HELPER_HASH"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/usr/bin/shasum -a 256 "${10}"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/usr/bin/cut -d " " -f 1' "$INSTALLER"; then
    echo "not ok - exact legacy hashes are not both checked before cleanup"
    exit 1
fi

if ! /usr/bin/grep -Fq 'OLD_SCOPED_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq 'OLD_SCOPED_TIMEOUT_HASH=' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '"$OLD_SCOPED_HASH" "$OLD_SCOPED_TIMEOUT_HASH"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '[ "$status" -eq 0 ] && [ -e "$7" ]' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '[ "$actual" = "$5" ] || [ "$actual" = "$6" ]' "$INSTALLER" \
    || ! /usr/bin/grep -Fq 'else' "$INSTALLER" \
    || ! /usr/bin/grep -Fq 'status=1' "$INSTALLER"; then
    echo "not ok - current-UID v1 migration does not fail closed on modified bytes"
    exit 1
fi

if ! /usr/bin/grep -Fq '/bin/rm -f "$7"' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/bin/rm -f "${10}"' "$INSTALLER"; then
    echo "not ok - exact-match legacy cleanup is missing"
    exit 1
fi

SUDO_TRANSACTION_COUNT="$(/usr/bin/grep -Fc '/usr/bin/sudo /bin/sh -c' "$INSTALLER")"
if [[ "$SUDO_TRANSACTION_COUNT" != "1" ]] \
    || ! /usr/bin/grep -Fq 'if [ "$status" -ne 0 ]; then' "$INSTALLER" \
    || ! /usr/bin/grep -Fq '/bin/rm -f "$4"' "$INSTALLER"; then
    echo "not ok - install, migration, and v2 rollback are not one privileged transaction"
    exit 1
fi

for REQUIRED in \
    'ROOT_TMP="/etc/sudoers.d/.steampack-pmset-v2-$USER_ID-' \
    '/usr/bin/cmp -s - "$2"' \
    '/usr/sbin/visudo -cf "$2"' \
    '/bin/mv -f "$2" "$4"'; do
    if ! /usr/bin/grep -Fq "$REQUIRED" "$INSTALLER"; then
        echo "not ok - root-owned validate-and-move install gate is incomplete"
        exit 1
    fi
done

echo "10 tests passed; 0 failed"
