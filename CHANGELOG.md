# Changelog

## 1.4.0 Public Preview

- Added native macOS Control Center controls for Keep Awake and Closed Lid.
- Added complete Korean localization for the app, alerts, notifications, and Control Center.
- Added Korean and English product visuals plus start-to-finish guides.
- Replaced technical Clamshell labels with clearer Closed Lid user-facing copy.
- Added linked master/child control behavior.
- Added a pipe-lease watchdog that restores sleep after crashes and SIGKILL.
- Added token-scoped ownership to prevent stale-watchdog races and external-state takeover.
- Added automatic Clamshell disarm at 20% battery and serious/critical thermal pressure.
- Added in-app installation and removal of the restricted sudoers permission.
- Separated requested and applied Control Center state with a liveness heartbeat.
- Added tests for safety policy, ownership, watchdog recovery decisions, and shared state.
- Added a release gate that requires Developer ID signing and Apple notarization.
