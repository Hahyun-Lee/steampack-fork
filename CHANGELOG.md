# Changelog

## 1.4.0 Public Preview

### Controls

- Added **Keep Awake** and **Closed Lid** controls for macOS Control Center.
- Linked the two modes so turning off Keep Awake restores normal sleep behavior.
- Changed the user-facing name from Clamshell to Closed Lid.

### Safety

- Restores normal lid-close sleep after crashes and force quits.
- Turns Closed Lid off at 20% battery, under serious thermal pressure, or when its timer ends.
- Shows the state applied by macOS and returns Control Center to OFF when the app stops responding.
- Limits administrator access to the two `pmset disablesleep` commands used by Closed Lid.

### Language and documentation

- Added Korean to the app, notifications, permission flow, and Control Center.
- Added English and Korean build, setup, safe-use, and removal instructions.

### Distribution

- This preview is source-only. The release script requires Developer ID signing and Apple notarization before producing a public binary.
