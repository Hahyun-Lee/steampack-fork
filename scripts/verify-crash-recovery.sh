#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BINARY="${APP_BINARY:-$ROOT_DIR/build/SteamPack.app/Contents/MacOS/SteamPack}"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Build SteamPack first: DEVELOPMENT_TEAM=<TEAM_ID> scripts/build.sh"
  exit 1
fi

sleep_disabled() {
  /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'
}

if sleep_disabled; then
  echo "Refusing to run: sleep is already disabled by SteamPack or another tool."
  exit 1
fi

if ! /usr/bin/sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null 2>&1 \
  || ! /usr/bin/sudo -n -l /usr/bin/pmset disablesleep 0 >/dev/null 2>&1; then
  echo "The restricted SteamPack permission is not installed."
  exit 1
fi

TEST_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/steampack-watchdog.XXXXXX")"
TOKEN="watchdog-test-$$"
OWNERSHIP_FILE="$TEST_DIR/clamshell-owner.json"
WATCHDOG_PID=""

cleanup() {
  /usr/bin/sudo -n /usr/bin/pmset disablesleep 0 >/dev/null 2>&1 || true
  if [[ -n "$WATCHDOG_PID" ]]; then
    /bin/kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
  fi
  /usr/bin/trash "$TEST_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

/usr/bin/printf '{"token":"%s","processID":%d,"startedAt":0}\n' \
  "$TOKEN" "$$" > "$OWNERSHIP_FILE"

# Keeping this pipe open models the app's live lease. When the writer exits,
# the watchdog receives EOF just as it would after a crash or SIGKILL.
( /bin/sleep 2 ) | "$APP_BINARY" --clamshell-watchdog "$TOKEN" "$OWNERSHIP_FILE" &
WATCHDOG_PID=$!

/usr/bin/sudo -n /usr/bin/pmset disablesleep 1
sleep_disabled || { echo "Failed to enable the test sleep setting."; exit 1; }

wait "$WATCHDOG_PID"
WATCHDOG_PID=""

if sleep_disabled; then
  echo "Crash recovery failed: sleep is still disabled."
  exit 1
fi

if [[ -e "$OWNERSHIP_FILE" ]]; then
  echo "Crash recovery failed: the ownership lease was not cleared."
  exit 1
fi

echo "Crash recovery verified: normal lid-close sleep was restored."
