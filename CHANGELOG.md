# Changelog

## 1.4.0 Public Preview

- Added native macOS Control Center controls for Keep Awake and Clamshell Mode.
- Added linked master/child control behavior.
- Added a pipe-lease watchdog that restores sleep after crashes and SIGKILL.
- Added token-scoped ownership to prevent stale-watchdog races and external-state takeover.
- Added automatic Clamshell disarm at 20% battery and serious/critical thermal pressure.
- Added in-app installation and removal of the restricted sudoers permission.
- Separated requested and applied Control Center state with a liveness heartbeat.
- Added tests for safety policy, ownership, watchdog recovery decisions, and shared state.
- Added a release gate that requires Developer ID signing and Apple notarization.
