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
- Publishes applied state and app liveness together in one atomic record; a missing, corrupt, failed-write, expired, or invalidated record is unavailable rather than a verified OFF.
- Periodically rereads macOS power-management state so changes made outside SteamPack are reflected in the app and Control Center.
- Waits for a revisioned applied-state acknowledgement before a Control Center action succeeds, recovers a missed Darwin notification on the heartbeat, and ignores duplicated request revisions.
- Uses one Closed Lid state transition on both surfaces: Closed Lid OFF returns to Keep Awake, and Keep Awake OFF returns to normal sleep.
- Limits administrator access to the two `pmset disablesleep` commands used by Closed Lid, with separate numeric-UID rules so one account cannot replace or remove another account's permission.
- Bounds the privileged `pmset` call with a `command_timeout` in the sudoers rule so sudo terminates a stuck child even if the app's own runner cannot reach it, and reverifies the live `SleepDisabled` state after enabling Closed Lid so a zero exit code alone never publishes success.

### Language and documentation

- Added Korean to the app, notifications, permission flow, and Control Center.
- Added English and Korean build, setup, safe-use, and removal instructions.

### Distribution

- This preview is source-only. The release script requires Developer ID signing and Apple notarization before producing a public binary.
- Build 9 advances both the app and embedded Control extension. It rejects unsealed or stale installations and confirms complete, revisioned state before an action succeeds. SteamPack relies on macOS to refresh the tapped Control Center source, refreshes a changed sibling immediately and once more after half a second, and applies the same bounded two-attempt policy to controls changed from its status menu. Exceptional failure and invalidation paths may refresh both controls but never create a periodic or whole-extension reload loop. Exact-candidate identity and the live latency/transition matrix remain release gates.
