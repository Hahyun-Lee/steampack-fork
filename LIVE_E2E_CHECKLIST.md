# Installed-app Control Center checklist

This check is required before publishing a signed build. Unit tests verify the state model, but they cannot prove that macOS has refreshed an already-installed Control Center extension or its visible tile cache.

## Install and identify the exact candidate

1. Replace the existing app with a properly signed candidate and launch it once. Never use a `CODE_SIGNING_ALLOWED=NO` product for Control Center testing. If no development identity is available, `bash scripts/build-local-adhoc.sh` creates a correctly sealed local-only ad-hoc candidate. This can diagnose behavior, but it cannot approve a public binary.
2. Run `bash scripts/verify-installed-versions.sh`. For the local-only ad-hoc candidate, compare the installed code to the exact source candidate with `ALLOW_ADHOC_SIGNING=1 bash scripts/verify-installed-versions.sh /Applications/SteamPack.app build/adhoc/SteamPack.app`. The gate checks the app and extension version, bundle identifiers, strict nested signature, matching signing team, sandbox entitlement, architectures, CDHashes, and the single PlugInKit registration path. A plist-only version match is not enough.
3. Keep any Control Center tiles created by the previous build in place. The upgrade itself must refresh them; do not hide a cache failure by deleting and recreating the tiles.
4. Exit **Edit Controls** before judging live state. The editor/gallery may show preview or cached presentation; only the normal Control Center surface is authoritative for `currentValue()`.

## Transition matrix

Except for the quit row, compare all four surfaces: the SteamPack status-item icon/text in the menu bar, `pmset -g` (`SleepDisabled`), the local `applied-state.json`, and both visible Control Center tiles. If either SteamPack control is pinned in the menu bar, compare that pinned control with the same control in the open panel too. After quit, check process absence, restored `pmset`, an expired/invalidated applied-state record, and unavailable Control Center providers.

| Transition | Required result |
|---|---|
| Launch in Normal Sleep | `SleepDisabled=0`; atomic applied state is OFF/OFF; both tiles are OFF. |
| Normal → Keep Awake → Normal | Keep Awake alone turns ON, then both surfaces return OFF. |
| Normal → Closed Lid → Normal | Both controls turn ON; turning Keep Awake off restores `SleepDisabled=0` and both tiles OFF. |
| Closed Lid → Closed Lid OFF → Normal | Turning Closed Lid off leaves Keep Awake ON on both menu and Control Center surfaces; turning Keep Awake off then restores both controls to OFF. |
| Normal Control Center → Closed Lid ON/OFF | The action is acknowledged only after the complete mode is applied. The tapped tile and any changed sibling converge within 1 second in normal Control Center. Record click, applied-state, and visible-convergence timestamps separately. |
| Normal → Closed Lid ON → Closed Lid OFF within 0.5 seconds | Keep Awake remains ON. Its retry from the first action still runs even though the Closed Lid source changes again, and both visible tiles converge within 1 second. |
| Control Center closed → enable Closed Lid from the SteamPack status menu → open Control Center immediately | The SteamPack status item, applied state, eye tile, and laptop tile all show ON/ON within 1 second. A half-eye or slashed laptop while local state is ON/ON is a release blocker. Changed tiles converge through the immediate targeted reload plus at most one targeted retry after half a second; they do not wait for the ten-second runtime refresh. |
| Closed Lid OFF → Keep Awake OFF | The eye remains ON while the laptop turns OFF after the first action; both turn OFF after the second. The status item, any pinned control, and panel tiles agree within 1 second after each action. |
| Closed Lid → external `pmset disablesleep 0` | Within 10 seconds SteamPack records a newer OFF request, cancels an auto-off countdown, and both tiles return OFF without replaying the old ON request. |
| Closed Lid → watchdog/app failure | Normal sleep is restored or a visible recovery failure is reported; stale ON is never presented as current. |
| Running any mode → Quit & Restore Sleep | Normal sleep is restored, the applied-state record is invalidated, and within 6 seconds both controls report unavailable—not OFF. Using either control instructs the user to open SteamPack. |
| Relaunch after failure/quit | No prior ON state appears during launch. |

Record timestamped screenshots plus the command and state-file logs for the observed surfaces in each row. A fresh applied OFF record must display OFF; a missing or expired record after quit or failure must report unavailable rather than present either Boolean as current. Confirm that logs contain no `reloadAllControls`, no periodic reload loop, and at most the immediate request plus one delayed targeted request for an app/menu change. A short screen capture is optional. If normal Control Center does not match the verified local state within the row's limit, treat it as a release blocker and preserve the installed app/extension versions, signing/registration receipt, and macOS build. Unit tests and **Edit Controls** screenshots do not pass this matrix.

Before publishing a binary, repeat the entire matrix with the exact app installed from the final notarized DMG. Record the source commit and release tag, DMG filename and SHA-256, app and extension version/build/IDs, signing team, per-architecture CDHashes, exact PlugInKit path, macOS build, and timestamp. An ad-hoc result is local diagnostic evidence only and must never be promoted to a notarized-release result.

[한국어](LIVE_E2E_CHECKLIST_ko.md)
