# Changelog

## 1.4.0 Public Preview

### Controls

- Added **Keep Awake** and **Closed Lid** controls for macOS Control Center.
- Linked the two modes so turning off Keep Awake restores normal sleep behavior.
- Changed the user-facing name from Clamshell to Closed Lid.

### Safety

- Attempts to restore normal lid-close sleep after crashes and force quits; reports failures and retains ownership for an authorized retry.
- Blocks or turns Closed Lid off at or below 20% battery, when power telemetry is unavailable, under serious or critical thermal pressure, or when its timer ends.
- Isolates every Closed Lid enable cycle with a token and process-start identity so stale watchdogs and reused PIDs cannot take over a newer session.
- Serializes Control Center requests in one revisioned record so late or concurrent notifications cannot revive an older mode.
- Publishes applied state and app liveness together in one atomic record; providers evaluate a missing, failed, or expired record as OFF, while visible Control Center tile convergence remains a required installed-build release check.
- Periodically rereads macOS power-management state so changes made outside SteamPack are reflected in the app and Control Center.
- Limits administrator access to the two `pmset disablesleep` commands used by Closed Lid, with separate numeric-UID rules so one account cannot replace or remove another account's permission.

### Language and documentation

- Added Korean to the app, notifications, permission flow, and Control Center.
- Added English and Korean build, setup, safe-use, and removal instructions.

### Distribution

- This preview is source-only. The release script requires Developer ID signing and Apple notarization before producing a public binary.
- Build 7 advances both the app and embedded Control extension, and adds an installed-version check plus a required live Control Center transition matrix.
