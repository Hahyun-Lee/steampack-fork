# Installed-app Control Center checklist

This check is required before publishing a signed build. Unit tests verify the state model, but they cannot prove that macOS has refreshed an already-installed Control Center extension or its visible tile cache.

## Install and identify the exact candidate

1. Replace the existing app with the signed candidate and launch it once.
2. Run `bash scripts/verify-installed-versions.sh`. Both the app and embedded Control extension must report **1.4.0 (7)**. A build-6 extension is a failed installation, even if the outer app looks current.
3. Keep any Control Center tiles created by the previous build in place. The upgrade itself must refresh them; do not hide a cache failure by deleting and recreating the tiles.

## Transition matrix

For every row, compare all four surfaces: the menu-bar icon/text, `pmset -g` (`SleepDisabled`), the local `applied-state.json`, and both visible Control Center tiles.

| Transition | Required result |
|---|---|
| Launch in Normal Sleep | `SleepDisabled=0`; atomic applied state is OFF/OFF; both tiles are OFF. |
| Normal → Keep Awake → Normal | Keep Awake alone turns ON, then both surfaces return OFF. |
| Normal → Closed Lid → Normal | Both controls turn ON; turning Keep Awake off restores `SleepDisabled=0` and both tiles OFF. |
| Closed Lid → external `pmset disablesleep 0` | Within 10 seconds SteamPack records a newer OFF request, cancels an auto-off countdown, and both tiles return OFF without replaying the old ON request. |
| Closed Lid → watchdog/app failure | Normal sleep is restored or a visible recovery failure is reported; stale ON is never presented as current. |
| Running OFF → quit app | Within 6 seconds both tiles show OFF; using one instructs the user to open SteamPack. |
| Relaunch after failure/quit | No prior ON state appears during launch. |

Record timestamped screenshots plus the command and state-file logs for the four observed surfaces in each row. A short screen capture is optional, not required. If the menu bar and local files are OFF while either tile stays ON, treat it as a release blocker and preserve the installed app/extension versions and macOS build with the report. Do not claim this matrix passed from unit-test results alone.

[한국어](LIVE_E2E_CHECKLIST_ko.md)
