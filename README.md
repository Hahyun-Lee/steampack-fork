<div align="right">

[![한국어](https://img.shields.io/badge/lang-한국어-red?style=flat-square)](README_ko.md)

</div>

<div align="center">

<img src="assets/hero-en.png" width="100%" alt="SteamPack keeps uploads, builds, and remote work running on a fully closed laptop">

# SteamPack — Close the lid. Keep the work running.

**Two simple macOS controls for staying awake with the lid open or closed.**

[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![English + 한국어](https://img.shields.io/badge/UI-English%20%2B%20한국어-orange?style=flat-square)](README_ko.md)

</div>

SteamPack is a small open-source menu bar app for long uploads, builds, backups, and remote sessions. Its controls can live in macOS Control Center or directly in the menu bar.

## Pick the control you need

| Control | What it does | Best for | Permission |
|---|---|---|---|
| **Keep Awake** | Prevents idle, display, and disk sleep while the lid is open | Presentations, downloads, builds | None |
| **Closed Lid** | Keeps work running after the lid closes, including on battery | Uploads, remote access, long agents | One restricted administrator approval |

Turning **Closed Lid** on also turns **Keep Awake** on. Turning **Keep Awake** off restores all normal sleep behavior.

> **Source preview:** a public DMG is intentionally unavailable until Developer ID signing and Apple notarization are ready. The current release is for people comfortable building from source.

## Start to finish

### 1. Build and install

You need macOS Tahoe 26+, Xcode 26, [Homebrew](https://brew.sh), XcodeGen, and an Apple Development team. A free Apple ID team works.

```bash
git clone https://github.com/Hahyun-Lee/steampack-fork.git
cd steampack-fork
brew install xcodegen
DEVELOPMENT_TEAM=YOUR_10_CHARACTER_TEAM_ID scripts/build.sh
ditto build/SteamPack.app /Applications/SteamPack.app
open /Applications/SteamPack.app
```

If you prefer Xcode, run `xcodegen generate`, open `SteamPack.xcodeproj`, choose your team for both app targets under **Signing & Capabilities**, and run the **SteamPack** scheme.

### 2. Turn on the right mode

Click the SteamPack icon in the menu bar.

- Choose **Turn Keep Awake On** when the lid will stay open. No administrator permission is needed.
- Choose **Install Closed-Lid Permission…** once, approve the macOS prompt, then choose **Keep Working with Lid Closed** when you need to close the lid.

The installed rule permits only these two exact commands. SteamPack never stores or pipes an administrator password.

```text
/usr/bin/pmset disablesleep 1
/usr/bin/pmset disablesleep 0
```

### 3. Add the two controls

1. Open macOS **Control Center**.
2. Choose **Edit Controls**.
3. Add **SteamPack Keep Awake** and **SteamPack Closed Lid**.
4. Optionally pin either control directly to the menu bar.

The SteamPack app must be running. If it is not, the controls show OFF and ask you to open the app.

### 4. Use it safely

Turn on the mode, confirm the menu says it is active, and keep the MacBook on a hard, ventilated surface. Never put a working closed MacBook inside a bag.

SteamPack automatically turns **Closed Lid** off when:

- battery reaches 20% while unplugged;
- macOS reports serious or critical thermal pressure;
- the auto-off timer expires;
- you choose **Quit & Restore Sleep**;
- the app crashes or is force-killed.

### 5. Stop or remove it

For everyday use, turn **Keep Awake** off to restore every normal sleep setting.

To uninstall completely:

1. Choose **Remove Closed-Lid Permission…** in the SteamPack menu.
2. Choose **Quit & Restore Sleep**.
3. Move `SteamPack.app` from Applications to the Trash.

## English and Korean UI

SteamPack follows the macOS language setting. To choose a language only for SteamPack, open **System Settings → General → Language & Region → Applications**, add SteamPack, and select English or Korean.

## Safety by design

- **Crash recovery:** every Closed-Lid session has a separate pipe-lease watchdog that restores normal lid-close sleep after a crash or SIGKILL.
- **Session ownership:** an old watchdog cannot turn off a newer session, and SteamPack refuses to claim a sleep state created by another tool.
- **Confirmed state:** Control Center shows the applied state rather than an optimistic request and fails closed when the app heartbeat stops.
- **Battery and thermal cutoffs:** 20% battery, serious heat, and critical heat restore normal lid-close sleep.
- **Minimal privilege:** no shell, wildcard arguments, stored password, telemetry, account, or network request.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Controls are missing | Confirm macOS 26+, launch SteamPack once, then reopen **Edit Controls**. |
| A control says to open SteamPack | Launch `/Applications/SteamPack.app`; the controls intentionally fail closed. |
| Closed Lid will not turn on | Install the restricted permission from the app menu and try again. |
| Closed Lid is unavailable | Another app or command owns the global `SleepDisabled` state. Restore that tool first. |
| Korean UI does not appear | Select Korean for SteamPack in **Language & Region → Applications**, then relaunch. |

## Test and release integrity

```bash
xcodegen generate
xcodebuild \
  -project SteamPack.xcodeproj \
  -scheme SteamPack \
  -derivedDataPath /tmp/steampack-tests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

After building and installing the restricted permission, `scripts/verify-crash-recovery.sh` briefly enables `SleepDisabled`, closes the watchdog lease as a crashed app would, and verifies that normal sleep returns. It refuses to run if sleep is already disabled.

`scripts/release.sh` refuses to produce a public artifact without Developer ID signing and Apple notarization. A binary release must pass signature verification, notarization, stapling, and Gatekeeper assessment.

## Important limitations

- `pmset disablesleep` is undocumented macOS behavior and may change.
- Protection reduces risk but cannot make a heavily loaded closed laptop safe in a bag.
- SteamPack cannot coordinate ownership with another tool changing the same global `SleepDisabled` flag.

SteamPack has no telemetry, analytics, accounts, network requests, or stored passwords. See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

SteamPack is an MIT-licensed fork of [tykimos/steampack](https://github.com/tykimos/steampack). The original copyright and license are preserved.
