#!/bin/bash
# SteamPack Clamshell Mode sudoers installer (one administrator approval)
set -euo pipefail
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/steampack-pmset-sudoers"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT
USER_NAME="$(/usr/bin/id -un)"

if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsupported macOS account name."
    exit 1
fi

/usr/bin/sed "s/__USER__/$USER_NAME/" "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP"
/usr/bin/sudo /usr/bin/install -m 0440 -o root -g wheel \
    "$TMP" /etc/sudoers.d/steampack-pmset

/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null
/usr/bin/sudo -n -l /usr/bin/pmset disablesleep 0 >/dev/null
echo "Installed restricted Clamshell permission for $USER_NAME."
