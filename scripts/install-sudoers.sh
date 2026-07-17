#!/bin/bash
# SteamPack Clamshell Mode sudoers installer (one administrator approval)
set -euo pipefail
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/steampack-pmset-sudoers"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT
USER_ID="$(/usr/bin/id -u)"
USER_NAME="$(/usr/bin/id -un)"
SUDOERS_PATH="/etc/sudoers.d/steampack-pmset-$USER_ID"
ROOT_TMP="/etc/sudoers.d/.steampack-pmset-$USER_ID-$(/usr/bin/uuidgen)"
LEGACY_PATH="/etc/sudoers.d/steampack-pmset"

if [[ ! "$USER_ID" =~ ^[0-9]+$ ]] || [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsupported macOS account identity."
    exit 1
fi

/usr/bin/sed "s/__UID__/$USER_ID/g" "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP"
EXPECTED_RULE="#$USER_ID ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"

# Copy first to an ignored, root-owned file; then compare against the inline
# expected bytes, validate that root-owned copy, and atomically move it into
# place. This closes the validation-to-install race on the user-owned temp file.
/usr/bin/sudo /bin/sh -c '
status=0
/usr/bin/install -m 0440 -o root -g wheel "$1" "$2" \
    && /usr/bin/printf "%s\n" "$3" | /usr/bin/cmp -s - "$2" \
    && /usr/sbin/visudo -cf "$2" >/dev/null \
    && /bin/mv -f "$2" "$4" \
    || status=$?
/bin/rm -f "$2"
exit "$status"
' steampack-rule-install "$TMP" "$ROOT_TMP" "$EXPECTED_RULE" "$SUDOERS_PATH"

# Remove a pre-1.4 shared rule only when its complete contents are one of the
# two exact formats SteamPack previously shipped for this same account. The
# expected strings are passed as fixed arguments, so another account's rule is
# never globbed, rewritten, or removed.
LEGACY_APP_RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
LEGACY_HELPER_RULE="# SteamPack Clamshell Mode (Battery) — pmset disablesleep 전용 NOPASSWD
# 정확한 인자 2개만 허용 (와일드카드 금지 — 다른 pmset 조작 차단)
# $USER_NAME 는 install-sudoers.sh가 설치 시점에 \$(whoami)로 치환한다.
$LEGACY_APP_RULE"
LEGACY_APP_HASH="$(/usr/bin/printf "%s\n" "$LEGACY_APP_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
LEGACY_HELPER_HASH="$(/usr/bin/printf "%s\n" "$LEGACY_HELPER_RULE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
/usr/bin/sudo /bin/sh -c '
actual=$(/usr/bin/shasum -a 256 "$3" 2>/dev/null | /usr/bin/cut -d " " -f 1)
if [ "$actual" = "$1" ] || [ "$actual" = "$2" ]; then
    /bin/rm -f "$3"
fi
' steampack-legacy-cleanup "$LEGACY_APP_HASH" "$LEGACY_HELPER_HASH" "$LEGACY_PATH"

/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null
/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 0 >/dev/null
echo "Installed restricted Clamshell permission for $USER_NAME (UID $USER_ID)."
