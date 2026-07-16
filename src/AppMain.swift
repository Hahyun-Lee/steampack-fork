import Cocoa
import ServiceManagement
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    let sleepToggle = SleepToggle()
    let clamshellMode = ClamshellMode()
    let safetyMonitor = PowerSafetyMonitor()

    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var clamshellMenuItem: NSMenuItem!
    private var safetyMenuItem: NSMenuItem!
    private var authorizationMenuItem: NSMenuItem!
    private var scheduledMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!

    private var sleepTimer: Timer?
    private var timerEndDate: Date?
    private var countdownTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lastSafetyEvent: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableSuddenTermination()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        registerControlObservers()
        configureSafety()
        startHeartbeat()

        clamshellMode.onWatchdogFailure = { [weak self] in
            self?.lastSafetyEvent = SteamPackL10n.text(
                "Watchdog stopped — normal sleep restored"
            )
            PowerSafetyNotifier.notifyWatchdogFailure()
            self?.updateMenu()
        }

        safetyMonitor.start()
        updateMenu()
    }

    // MARK: - Control Center

    func onKeepAwakeRequest() {
        let requested = SteamPackShared.readRequestedKeepAwake()
        if requested {
            let wantsClamshell = SteamPackShared.readRequestedClamshell()
            if wantsClamshell {
                switch enableClamshell() {
                case .success:
                    break
                case .failed(let message):
                    PowerSafetyNotifier.notifyControlFailure(message)
                }
            } else if !sleepToggle.isDisableSleep {
                _ = sleepToggle.toggle()
            }
        } else {
            stopAllKeepAwakeModes()
        }
        updateMenu()
    }

    func onClamshellRequest() {
        let requested = SteamPackShared.readRequestedClamshell()
        if requested {
            switch enableClamshell() {
            case .success:
                break
            case .failed(let message):
                PowerSafetyNotifier.notifyControlFailure(message)
            }
        } else {
            let result = clamshellMode.set(false)
            if case .success = result, !sleepToggle.isDisableSleep {
                _ = sleepToggle.toggle()
            }
        }
        updateMenu()
    }

    private func registerControlObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { delegate.onKeepAwakeRequest() }
            },
            SteamPackShared.keepAwakeRequestName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { delegate.onClamshellRequest() }
            },
            SteamPackShared.clamshellRequestName,
            nil,
            .deliverImmediately
        )
    }

    private func startHeartbeat() {
        SteamPackShared.publishHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            SteamPackShared.publishHeartbeat()
        }
    }

    private func publishState() {
        SteamPackShared.publishApplied(
            keepAwake: sleepToggle.isDisableSleep || clamshellMode.isOn,
            clamshell: clamshellMode.isOn
        )
        ControlCenter.shared.reloadControls(ofKind: SteamPackShared.keepAwakeKind)
        ControlCenter.shared.reloadControls(ofKind: SteamPackShared.clamshellKind)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.keepAwakeKind)
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.clamshellKind)
        }
    }

    // MARK: - Safety

    private func configureSafety() {
        safetyMonitor.onUpdate = { [weak self] _ in
            self?.updateSafetyMenuItem()
        }
        safetyMonitor.onUnsafe = { [weak self] issue in
            guard let self, self.clamshellMode.isOn else { return }
            let result = self.clamshellMode.set(false)
            guard case .success = result else { return }
            self.lastSafetyEvent = SteamPackL10n.format(
                "Safety restored sleep — %@",
                issue.description
            )
            PowerSafetyNotifier.notifyAutomaticDisarm(issue)
            self.updateMenu()
        }
    }

    private func enableClamshell() -> ClamshellMode.ToggleResult {
        safetyMonitor.refresh()
        if let issue = PowerSafetyPolicy.issue(for: safetyMonitor.snapshot) {
            return .failed(SteamPackL10n.format(
                "Closed-Lid mode was blocked for safety. %@.",
                issue.description
            ))
        }

        PowerSafetyNotifier.prepare()
        let result = clamshellMode.set(true)
        if case .success = result, sleepToggle.isDisableSleep {
            _ = sleepToggle.toggle()
        }
        return result
    }

    private func stopAllKeepAwakeModes() {
        if sleepToggle.isDisableSleep {
            _ = sleepToggle.toggle()
        }
        if clamshellMode.isOn {
            _ = clamshellMode.set(false)
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(
            title: "",
            action: #selector(toggleKeepAwake),
            keyEquivalent: "t"
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        clamshellMenuItem = NSMenuItem(
            title: "",
            action: #selector(toggleClamshell),
            keyEquivalent: "c"
        )
        clamshellMenuItem.target = self
        menu.addItem(clamshellMenuItem)

        safetyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        safetyMenuItem.isEnabled = false
        menu.addItem(safetyMenuItem)

        authorizationMenuItem = NSMenuItem(
            title: "",
            action: #selector(toggleClamshellAuthorization),
            keyEquivalent: ""
        )
        authorizationMenuItem.target = self
        menu.addItem(authorizationMenuItem)

        menu.addItem(.separator())
        setupScheduleMenu(in: menu)
        menu.addItem(.separator())

        loginItemMenuItem = NSMenuItem(
            title: "",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)

        let quitItem = NSMenuItem(
            title: SteamPackL10n.text("Quit & Restore Sleep"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupScheduleMenu(in menu: NSMenu) {
        scheduledMenuItem = NSMenuItem(
            title: SteamPackL10n.text("Auto-Off Timer"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        let durations: [(String, TimeInterval)] = [
            (SteamPackL10n.text("10 Minutes"), 10 * 60),
            (SteamPackL10n.text("30 Minutes"), 30 * 60),
            (SteamPackL10n.text("1 Hour"), 60 * 60),
            (SteamPackL10n.text("2 Hours"), 2 * 60 * 60),
            (SteamPackL10n.text("4 Hours"), 4 * 60 * 60)
        ]
        for (title, seconds) in durations {
            let item = NSMenuItem(title: title, action: #selector(scheduleSleep(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let cancel = NSMenuItem(
            title: SteamPackL10n.text("Cancel Timer"),
            action: #selector(cancelScheduledSleep),
            keyEquivalent: ""
        )
        cancel.target = self
        submenu.addItem(cancel)
        scheduledMenuItem.submenu = submenu
        menu.addItem(scheduledMenuItem)
    }

    private func updateMenu() {
        sleepToggle.refresh()
        clamshellMode.refresh()
        statusMenuItem.title = statusText()
        toggleMenuItem.title = keepAwakeText()
        clamshellMenuItem.title = clamshellText()
        clamshellMenuItem.isEnabled = !clamshellMode.isExternallyDisabled
        authorizationMenuItem.title = clamshellMode.isAuthorized
            ? SteamPackL10n.text("Remove Closed-Lid Permission…")
            : SteamPackL10n.text("Install Closed-Lid Permission…")
        loginItemMenuItem.title = (isLoginItemEnabled ? "✓ " : "  ")
            + SteamPackL10n.text("Start at Login")
        updateSafetyMenuItem()
        updateIcon()
        publishState()
    }

    private func updateSafetyMenuItem() {
        guard safetyMenuItem != nil else { return }
        if let lastSafetyEvent {
            safetyMenuItem.title = "⚠ \(lastSafetyEvent)"
            return
        }

        let snapshot = safetyMonitor.snapshot
        let power: String
        if snapshot.isOnACPower {
            power = SteamPackL10n.text("AC power")
        } else if let percent = snapshot.batteryPercent {
            power = SteamPackL10n.format("Battery %d%%", percent)
        } else {
            power = SteamPackL10n.text("Battery")
        }
        let temperature: String
        switch snapshot.thermalState {
        case .nominal: temperature = SteamPackL10n.text("temperature normal")
        case .fair: temperature = SteamPackL10n.text("temperature elevated")
        case .serious, .critical: temperature = SteamPackL10n.text("temperature high")
        @unknown default: temperature = SteamPackL10n.text("temperature unknown")
        }
        safetyMenuItem.title = SteamPackL10n.format(
            "Safety: %@ · %@ · auto-off at 20%%",
            power,
            temperature
        )
    }

    private func statusText() -> String {
        if let endDate = timerEndDate {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow))
            return SteamPackL10n.format("Auto-off in %@", formatDuration(remaining))
        }
        if clamshellMode.isOn {
            return SteamPackL10n.text("Closed Lid — crash guard armed")
        }
        if clamshellMode.isExternallyDisabled {
            return SteamPackL10n.text("Sleep is disabled by another app or command")
        }
        return SteamPackL10n.text(
            sleepToggle.isDisableSleep ? "Keep Awake — lid open" : "Normal Sleep"
        )
    }

    private func keepAwakeText() -> String {
        SteamPackL10n.text(
            (sleepToggle.isDisableSleep || clamshellMode.isOn)
                ? "Turn Keep Awake Off"
                : "Turn Keep Awake On"
        )
    }

    private func clamshellText() -> String {
        (clamshellMode.isOn ? "✓ " : "  ")
            + SteamPackL10n.text("Keep Working with Lid Closed")
    }

    private func updateIcon() {
        let symbol: String
        if lastSafetyEvent != nil {
            symbol = "exclamationmark.triangle.fill"
        } else if sleepTimer != nil {
            symbol = "hourglass.badge.eye"
        } else if clamshellMode.isOn {
            symbol = "laptopcomputer"
        } else if sleepToggle.isDisableSleep {
            symbol = "eye.fill"
        } else {
            symbol = "eye.half.closed.fill"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText()) {
            image.isTemplate = true
            statusItem.button?.image = image
        }

        if let endDate = timerEndDate {
            statusItem.button?.title = " " + formatDuration(max(0, Int(endDate.timeIntervalSinceNow)))
        } else {
            statusItem.button?.title = ""
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let seconds = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    @objc private func toggleKeepAwake() {
        lastSafetyEvent = nil
        cancelTimerWithoutUpdating()
        if sleepToggle.isDisableSleep || clamshellMode.isOn {
            stopAllKeepAwakeModes()
        } else {
            _ = sleepToggle.toggle()
        }
        updateMenu()
    }

    @objc private func toggleClamshell() {
        lastSafetyEvent = nil
        cancelTimerWithoutUpdating()
        let result = clamshellMode.isOn ? clamshellMode.set(false) : enableClamshell()
        if case .failed(let message) = result {
            showAlert(title: SteamPackL10n.text("Closed-Lid Mode"), message: message)
        }
        updateMenu()
    }

    @objc private func toggleClamshellAuthorization() {
        if clamshellMode.isAuthorized {
            if clamshellMode.isOn, case .failed(let message) = clamshellMode.set(false) {
                showAlert(title: SteamPackL10n.text("Closed-Lid Permission"), message: message)
                return
            }
            let alert = NSAlert()
            alert.messageText = SteamPackL10n.text("Remove Closed-Lid permission?")
            alert.informativeText = SteamPackL10n.text(
                "Keep Awake will continue to work, but closed-lid mode will be unavailable."
            )
            alert.addButton(withTitle: SteamPackL10n.text("Remove"))
            alert.addButton(withTitle: SteamPackL10n.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if case .failure(let error) = ClamshellAuthorization.remove() {
                showAlert(
                    title: SteamPackL10n.text("Closed-Lid Permission"),
                    message: error.localizedDescription
                )
            }
        } else {
            let alert = NSAlert()
            alert.messageText = SteamPackL10n.text(
                "Install restricted Closed-Lid permission?"
            )
            alert.informativeText = SteamPackL10n.text(
                "SteamPack will ask macOS once for administrator approval. The installed rule permits only the two exact pmset commands that turn closed-lid sleep prevention on and off."
            )
            alert.addButton(withTitle: SteamPackL10n.text("Install"))
            alert.addButton(withTitle: SteamPackL10n.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if case .failure(let error) = ClamshellAuthorization.install() {
                showAlert(
                    title: SteamPackL10n.text("Closed-Lid Permission"),
                    message: error.localizedDescription
                )
            }
        }
        updateMenu()
    }

    @objc private func scheduleSleep(_ sender: NSMenuItem) {
        lastSafetyEvent = nil
        if !sleepToggle.isDisableSleep && !clamshellMode.isOn {
            guard case .success = sleepToggle.toggle() else { return }
        }
        cancelTimerWithoutUpdating()

        let seconds = TimeInterval(sender.tag)
        timerEndDate = Date().addingTimeInterval(seconds)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
        updateMenu()
    }

    @objc private func cancelScheduledSleep() {
        cancelTimerWithoutUpdating()
        updateMenu()
    }

    private func cancelTimerWithoutUpdating() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        timerEndDate = nil
    }

    private func timerFired() {
        cancelTimerWithoutUpdating()
        stopAllKeepAwakeModes()
        updateMenu()
    }

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(
                title: SteamPackL10n.text("Start at Login"),
                message: error.localizedDescription
            )
        }
        updateMenu()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: SteamPackL10n.text("OK"))
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        safetyMonitor.stop()
        cancelTimerWithoutUpdating()
        stopAllKeepAwakeModes()
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        SteamPackShared.clearHeartbeat()
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        lastSafetyEvent = nil
        safetyMonitor.refresh()
        updateMenu()
    }
}

@main
enum Main {
    static func main() {
        if ClamshellWatchdog.runIfRequested() { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
