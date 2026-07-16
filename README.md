<div align="right">

[![한국어](https://img.shields.io/badge/lang-한국어-red?style=flat-square)](README_ko.md)

</div>

<div align="center">

# SteamPack

**Native Keep Awake and Closed-Lid controls for macOS Tahoe.**

[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)

</div>

SteamPack is a small, open-source menu bar utility with two linked native controls:

- **Keep Awake** prevents idle, display, and disk sleep while the lid is open.
- **Clamshell Mode** keeps the Mac running after the lid closes, including on battery.

Both controls can live in macOS Control Center or be pinned directly to the menu bar. Clamshell Mode is a child of Keep Awake: enabling it also enables Keep Awake, while turning Keep Awake off restores every sleep setting.

> **Public preview:** the source is ready for testing. A downloadable DMG will be published only after Developer ID signing and Apple notarization are available. SteamPack intentionally does not distribute an unsigned public binary.

## Why this exists

Long uploads, builds, backups, remote sessions, and local coding agents often need a MacBook to continue working after the lid closes. `caffeinate` cannot override lid-close sleep on battery. SteamPack provides a visible, reversible control without storing an administrator password.

## Safety model

Closed-lid operation can generate heat and drain a battery. SteamPack treats crash recovery as part of the feature, not an optional extra.

- **Crash/SIGKILL watchdog:** every Clamshell session owns a pipe lease. If the app crashes or is force-killed, a separate watchdog restores normal sleep.
- **Token-scoped ownership:** an old watchdog cannot turn off a newer session, and SteamPack does not claim a sleep state created by another app.
- **Battery cutoff:** Clamshell Mode turns off at 20% when running on battery.
- **Thermal cutoff:** serious or critical macOS thermal pressure immediately turns Clamshell Mode off.
- **Timers and quit cleanup:** auto-off timers and “Quit & Restore Sleep” restore normal sleep.
- **Truthful controls:** Control Center displays the last confirmed applied state, not an optimistic request. Controls fail closed when the menu bar app is not alive.
- **Restricted privilege:** the optional sudoers rule permits only these exact commands:

```text
/usr/bin/pmset disablesleep 1
/usr/bin/pmset disablesleep 0
```

SteamPack never stores or pipes an administrator password. Permission can be removed from the app at any time.

## Requirements

- macOS Tahoe 26.0 or later
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build from source
- A free Apple Development team for native Control Center rendering

## Build and run

```bash
git clone https://github.com/Hahyun-Lee/steampack-fork.git
cd steampack-fork
brew install xcodegen
xcodegen generate
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/build.sh
open build/SteamPack.app
```

You can also open `SteamPack.xcodeproj` in Xcode, select your development team for both app targets, and run the `SteamPack` scheme.

On first use of Clamshell Mode, choose **Install Clamshell Permission…**. macOS presents one administrator approval prompt. Keep Awake does not require this permission.

To add the controls:

1. Open macOS Control Center and choose **Edit Controls**.
2. Add **SteamPack Keep Awake** and **SteamPack Clamshell**.
3. Optionally pin either control directly to the menu bar.

## Testing

```bash
xcodegen generate
xcodebuild \
  -project SteamPack.xcodeproj \
  -scheme SteamPack \
  -derivedDataPath /tmp/steampack-tests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The tests cover battery and thermal policy, crash-recovery ownership, stale watchdog races, and Control Center heartbeat/state behavior.

After building and installing the restricted Clamshell permission, the following opt-in integration check briefly changes `SleepDisabled`, closes the watchdog lease as a crashed app would, and verifies that normal sleep is restored. It refuses to run if sleep is already disabled.

```bash
scripts/verify-crash-recovery.sh
```

## Release integrity

`scripts/release.sh` refuses to create a public artifact unless both a Developer ID Application identity and an Apple notarization profile are supplied. A release must pass deep signature verification, notarization, stapling, and Gatekeeper assessment.

## Important limitations

- `pmset disablesleep` is an undocumented macOS behavior and may change in a future release.
- Safety cutoffs reduce risk but cannot make a closed, heavily loaded MacBook safe inside a bag. Keep ventilation clear and use judgment.
- The menu bar app must remain running for Control Center actions. Stale controls automatically display off.
- SteamPack cannot safely coordinate ownership with another utility changing the same global `SleepDisabled` flag. It detects that state and refuses to claim it.

## Privacy and security

SteamPack has no telemetry, analytics, accounts, network requests, or stored passwords. See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## Attribution

SteamPack is an MIT-licensed fork of [tykimos/steampack](https://github.com/tykimos/steampack). The original copyright and license are preserved.
