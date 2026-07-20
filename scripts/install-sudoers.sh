#!/bin/bash
# SteamPack Clamshell Mode sudoers installer (one administrator approval)
set -euo pipefail
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/steampack-pmset-sudoers"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT
USER_ID="$(/usr/bin/id -u)"
USER_NAME="$(/usr/bin/id -un)"
SUDOERS_PATH="/etc/sudoers.d/steampack-pmset-v2-$USER_ID"
ROOT_TMP="/etc/sudoers.d/.steampack-pmset-v2-$USER_ID-$(/usr/bin/uuidgen)"
OLD_SCOPED_PATH="/etc/sudoers.d/steampack-pmset-$USER_ID"
LEGACY_PATH="/etc/sudoers.d/steampack-pmset"

if [[ ! "$USER_ID" =~ ^[0-9]+$ ]] || [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsupported macOS account identity."
    exit 1
fi

/usr/bin/sed "s/__UID__/$USER_ID/g" "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP"
# Each exact command carries its own one-second sudo timeout. This does not
# broaden the timeout to unrelated pmset grants. Keep these bytes identical to
# the rendered template and ClamshellAuthorizationLayout.rule.
EXPECTED_RULE="#$USER_ID ALL=(root) TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 1, TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 0"

# Hash every previously shipped rule before entering the privileged installer.
# Root removes a previous file only when the complete bytes match one of these
# account-specific SteamPack formats.
OLD_SCOPED_RULE="#$USER_ID ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
OLD_SCOPED_TIMEOUT_RULE="Defaults!/usr/bin/pmset command_timeout=5
$OLD_SCOPED_RULE"
OLD_SCOPED_HASH="$(/usr/bin/printf "%s\n" "$OLD_SCOPED_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
OLD_SCOPED_TIMEOUT_HASH="$(/usr/bin/printf "%s\n" "$OLD_SCOPED_TIMEOUT_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
LEGACY_APP_RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
LEGACY_HELPER_RULE="# SteamPack Clamshell Mode (Battery) — pmset disablesleep 전용 NOPASSWD
# 정확한 인자 2개만 허용 (와일드카드 금지 — 다른 pmset 조작 차단)
# $USER_NAME 는 install-sudoers.sh가 설치 시점에 \$(whoami)로 치환한다.
$LEGACY_APP_RULE"
LEGACY_APP_HASH="$(/usr/bin/printf "%s\n" "$LEGACY_APP_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
LEGACY_HELPER_HASH="$(/usr/bin/printf "%s\n" "$LEGACY_HELPER_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

# Copy first to an ignored, root-owned file; then compare against the inline
# expected bytes, validate that root-owned copy, and atomically move it into
# place. Migration cleanup and rollback run in this same privileged transaction:
# a cleanup failure removes v2 so an older grant is never silently accepted.
/usr/bin/sudo /bin/sh -c '
status=0
/usr/bin/install -m 0440 -o root -g wheel "$1" "$2" \
    && /usr/bin/printf "%s\n" "$3" | /usr/bin/cmp -s - "$2" \
    && /usr/sbin/visudo -cf "$2" >/dev/null \
    && /bin/mv -f "$2" "$4" \
    || status=$?
if [ "$status" -eq 0 ] && [ -e "$7" ]; then
    actual=$(/usr/bin/shasum -a 256 "$7" 2>/dev/null | /usr/bin/cut -d " " -f 1)
    if [ "$actual" = "$5" ] || [ "$actual" = "$6" ]; then
        /bin/rm -f "$7" || status=$?
    else
        status=1
    fi
fi
if [ "$status" -eq 0 ]; then
    actual=$(/usr/bin/shasum -a 256 "${10}" 2>/dev/null | /usr/bin/cut -d " " -f 1)
    if [ "$actual" = "$8" ] || [ "$actual" = "$9" ]; then
        /bin/rm -f "${10}" || status=$?
    fi
fi
if [ "$status" -ne 0 ]; then
    /bin/rm -f "$4"
fi
/bin/rm -f "$2"
exit "$status"
' steampack-rule-install \
    "$TMP" "$ROOT_TMP" "$EXPECTED_RULE" "$SUDOERS_PATH" \
    "$OLD_SCOPED_HASH" "$OLD_SCOPED_TIMEOUT_HASH" "$OLD_SCOPED_PATH" \
    "$LEGACY_APP_HASH" "$LEGACY_HELPER_HASH" "$LEGACY_PATH"

/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null
/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 0 >/dev/null
echo "Installed restricted Clamshell permission for $USER_NAME (UID $USER_ID)."
