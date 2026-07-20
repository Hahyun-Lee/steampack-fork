<div align="right">

[![한국어](https://img.shields.io/badge/lang-한국어-red?style=flat-square)](README_ko.md)

</div>

<div align="center">

<img src="assets/hero-en.png" width="100%" alt="SteamPack keeps uploads, builds, and remote work running on a fully closed laptop">

# SteamPack

**Close the lid without stopping an upload, build, or remote session.**

[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![English + 한국어](https://img.shields.io/badge/UI-English%20%2B%20한국어-orange?style=flat-square)](README_ko.md)

[Build from source](#install-from-source) · [Releases](https://github.com/Hahyun-Lee/steampack-fork/releases)

</div>

SteamPack is a macOS menu bar app with two controls: **Keep Awake** and **Closed Lid**. Use them from the app, Control Center, or the menu bar.

## Choose a mode

| Mode | What it does | Permission |
|---|---|---|
| **Keep Awake** | Prevents idle, display, and disk sleep while the lid is open | None |
| **Closed Lid** | Keeps the Mac running after the lid closes, including on battery | One administrator approval |

**Closed Lid** also turns on **Keep Awake**. Turning Closed Lid off returns to Keep Awake; turning Keep Awake off restores normal sleep behavior. The menu and Control Center use the same transitions.

Closed Lid is blocked or turns itself off when unplugged battery is at or below 20%, power telemetry is unavailable, macOS reports serious or critical thermal pressure, or the auto-off timer ends. If SteamPack stops unexpectedly, a watchdog attempts to restore normal sleep; failed restores are reported and retained for retry.

> There is no DMG in this preview. Build from source using your own Apple Development team. Public binaries will be added after Developer ID signing and Apple notarization are available.

## Install from source

Requirements: macOS Tahoe 26+, Xcode 26, [Homebrew](https://brew.sh), XcodeGen, and an Apple Development team. A free Apple ID team works.

```bash
git clone https://github.com/Hahyun-Lee/steampack-fork.git
cd steampack-fork
brew install xcodegen
DEVELOPMENT_TEAM=YOUR_10_CHARACTER_TEAM_ID scripts/build.sh
ditto build/SteamPack.app /Applications/SteamPack.app
open /Applications/SteamPack.app
```

To build in Xcode, run `xcodegen generate`, open `SteamPack.xcodeproj`, and select your team for both app targets under **Signing & Capabilities**. Then run the **SteamPack** scheme.

## Use SteamPack

Open the SteamPack menu bar icon and choose the mode you need.

- For downloads, presentations, or builds with the lid open, choose **Turn Keep Awake On**.
- To close the lid, choose **Install Closed-Lid Permission…** once and approve the macOS prompt. Then choose **Keep Working with Lid Closed**.
- When finished, turn **Keep Awake** off. Both modes return to normal sleep behavior.

The Closed Lid permission allows only these two commands:

```text
/usr/bin/pmset disablesleep 1
/usr/bin/pmset disablesleep 0
```

SteamPack does not store or pass along your administrator password.

The permission file is versioned and scoped to the current account's numeric user ID. Each exact command has a one-second privileged timeout. **Install Closed-Lid Permission…** migrates an older account-scoped or shared SteamPack rule only when its complete contents match a rule SteamPack previously installed. A modified account-scoped rule is preserved and the migration stops for manual review; **Remove Closed-Lid Permission…** never removes another account's rule.

## Add the Control Center controls

1. Open macOS **Control Center** and choose **Edit Controls**.
2. Add **SteamPack Keep Awake** and **SteamPack Closed Lid**.
3. Pin either control to the menu bar if you want quicker access.

The SteamPack app must be running. When its live applied state is unavailable, the controls report that they are unavailable instead of presenting an unverified OFF value; trying to use one displays an instruction to open SteamPack.

## Closed-lid safety

Keep a running MacBook on a hard, ventilated surface. Do not put it in a bag while Closed Lid is on.

SteamPack blocks or turns Closed Lid off when:

- battery is at or below 20% while unplugged;
- macOS cannot verify the power source, or cannot read battery level while unplugged;
- macOS reports serious or critical thermal pressure;
- the auto-off timer expires;
- you choose **Quit & Restore Sleep**.

A separate watchdog attempts to restore normal lid-close sleep if the app stops unexpectedly. If restoration fails, SteamPack reports that sleep prevention may still be active and retains the ownership record for an authorized retry. Each session has its own token, so an old watchdog cannot stop a newer session. SteamPack also refuses to take over a `SleepDisabled` state created by another tool.

The Control Center providers read the state that macOS actually applied. Each request carries a revision, and the control waits for the app to publish the complete verified result before reporting success. SteamPack relies on macOS to refresh the Control Center source you tapped; when a linked control also changed, SteamPack refreshes it immediately and retries that targeted refresh once after half a second. A change made from SteamPack's status menu follows the same immediate-plus-one-retry policy for affected controls, covering the case where Control Center opens just after the change. There is no periodic or whole-Control-Center reload loop. A missing or expired applied-state record is unavailable, not an unverified OFF. Visible convergence and response time must pass the [installed-app checklist](LIVE_E2E_CHECKLIST.md) in normal Control Center—not **Edit Controls**—before binary release.

## Uninstall

1. Choose **Remove Closed-Lid Permission…** in the SteamPack menu.
2. Choose **Quit & Restore Sleep**.
3. Move `SteamPack.app` from Applications to the Trash.

## Language

SteamPack follows the macOS language setting. To set a language only for SteamPack, open **System Settings → General → Language & Region → Applications**, add SteamPack, and choose English or Korean.

## Troubleshooting

| Problem | What to check |
|---|---|
| Controls are missing | Confirm macOS 26+, launch SteamPack once, then reopen **Edit Controls**. |
| A control asks to open SteamPack | Launch `/Applications/SteamPack.app`. |
| Closed Lid will not turn on | Install the Closed Lid permission from the app menu. |
| Closed Lid is unavailable | Another app or command owns the global `SleepDisabled` state. Restore that tool first. |
| Korean UI does not appear | Select Korean for SteamPack in **Language & Region → Applications**, then relaunch. |

## Tests

```bash
xcodegen generate
xcodebuild \
  -project SteamPack.xcodeproj \
  -scheme SteamPack \
  -derivedDataPath /tmp/steampack-tests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

After building and installing the Closed Lid permission, run `scripts/verify-crash-recovery.sh` to test watchdog recovery. The script refuses to run if sleep is already disabled.

For local Control Center testing without an Apple Development identity, `scripts/build-local-adhoc.sh` creates a correctly sealed, local-only app at `build/adhoc/SteamPack.app`. It is not a distributable build. Never install a `CODE_SIGNING_ALLOWED=NO` test product to evaluate the Control Center extension.

Before distributing a signed build, complete the [installed-app Control Center checklist](LIVE_E2E_CHECKLIST.md). It verifies the installed app and embedded extension versions, signatures, sandbox entitlement, PlugInKit registration, and visible tile transitions that unit tests cannot observe.

`scripts/release.sh` will not create a public binary unless signature verification, notarization, stapling, and Gatekeeper assessment all pass.

## Limitations

- `pmset disablesleep` is undocumented macOS behavior and may change.
- The safety cutoffs reduce risk; they do not make it safe to run a closed MacBook in a bag.
- SteamPack cannot share ownership with another tool that changes the global `SleepDisabled` flag.

SteamPack has no telemetry, analytics, accounts, network requests, or stored passwords. See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

SteamPack is an MIT-licensed fork of [tykimos/steampack](https://github.com/tykimos/steampack). The original copyright and license are preserved.
