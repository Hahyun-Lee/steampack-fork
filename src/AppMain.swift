import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let sleepToggle = SleepToggle()
    let clamshellMode = ClamshellMode()

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var clamshellMenuItem: NSMenuItem!
    private var scheduledMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!

    // Scheduled sleep timer
    private var sleepTimer: Timer?
    private var timerEndDate: Date?
    private var countdownTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        updateIcon()


    }

    private func setupMenu() {
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: toggleText(), action: #selector(toggleSleep), keyEquivalent: "t")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        clamshellMenuItem = NSMenuItem(title: clamshellText(), action: #selector(toggleClamshell), keyEquivalent: "c")
        clamshellMenuItem.target = self
        menu.addItem(clamshellMenuItem)

        // Scheduled sleep submenu
        scheduledMenuItem = NSMenuItem(title: "Scheduled Sleep", action: nil, keyEquivalent: "")
        let scheduledSubmenu = NSMenu()
        let durations: [(String, TimeInterval)] = [
            ("10 Minutes", 10 * 60),
            ("30 Minutes", 30 * 60),
            ("1 Hour", 60 * 60),
            ("2 Hours", 2 * 60 * 60),
            ("4 Hours", 4 * 60 * 60),
        ]
        for (title, seconds) in durations {
            let item = NSMenuItem(title: title, action: #selector(scheduleSleep(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            scheduledSubmenu.addItem(item)
        }
        scheduledSubmenu.addItem(NSMenuItem.separator())
        let cancelItem = NSMenuItem(title: "Cancel Timer", action: #selector(cancelScheduledSleep), keyEquivalent: "")
        cancelItem.target = self
        scheduledSubmenu.addItem(cancelItem)
        scheduledMenuItem.submenu = scheduledSubmenu
        menu.addItem(scheduledMenuItem)

        menu.addItem(NSMenuItem.separator())

        loginItemMenuItem = NSMenuItem(title: loginItemText(), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self  // 메뉴 열 때마다 caffeinate 생존 상태 재동기화
        statusItem.menu = menu
    }

    private func updateIcon() {
        let name: String
        if sleepTimer != nil {
            name = "hourglass.badge.eye"
        } else if clamshellMode.isOn {
            name = "laptopcomputer"
        } else if sleepToggle.isDisableSleep {
            name = "eye.fill"
        } else {
            name = "eye.half.closed.fill"
        }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sleep Toggle") {
            image.isTemplate = true
            statusItem.button?.image = image
        }

        // Show countdown next to icon
        if let endDate = timerEndDate {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow))
            let hours = remaining / 3600
            let minutes = (remaining % 3600) / 60
            let seconds = remaining % 60
            if hours > 0 {
                statusItem.button?.title = String(format: " %d:%02d:%02d", hours, minutes, seconds)
            } else {
                statusItem.button?.title = String(format: " %02d:%02d", minutes, seconds)
            }
        } else {
            statusItem.button?.title = ""
        }
    }

    private func updateMenu() {
        statusMenuItem.title = statusText()
        toggleMenuItem.title = toggleText()
        clamshellMenuItem.title = clamshellText()
        loginItemMenuItem.title = loginItemText()
        updateIcon()
    }

    private func statusText() -> String {
        if let endDate = timerEndDate {
            let remaining = max(0, endDate.timeIntervalSinceNow)
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            if hours > 0 {
                return "Sleep in \(hours)h \(minutes)m"
            } else {
                return "Sleep in \(minutes)m"
            }
        }
        if clamshellMode.isOn {
            return "Clamshell Mode — Sleep Off"
        }
        return sleepToggle.isDisableSleep ? "Sleep Disabled" : "Sleep Enabled"
    }

    private func toggleText() -> String {
        sleepToggle.isDisableSleep ? "Enable Sleep" : "Disable Sleep"
    }

    private func clamshellText() -> String {
        clamshellMode.isOn ? "✓ Clamshell Mode (Battery)" : "  Clamshell Mode (Battery)"
    }

    @objc private func toggleClamshell() {
        let result = clamshellMode.toggle()
        switch result {
        case .success:
            updateMenu()
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "Clamshell Mode"
            alert.informativeText = """
            sudo 권한이 필요합니다. 터미널에서 1회 실행:

            ~/steampack-fork/scripts/install-sudoers.sh

            (\(message))
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func loginItemText() -> String {
        isLoginItemEnabled ? "✓ Start at Login" : "  Start at Login"
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Login Item"
            alert.informativeText = "Failed to update login item: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func scheduleSleep(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)

        // If sleep is currently enabled, disable it first
        if !sleepToggle.isDisableSleep {
            let result = sleepToggle.toggle()
            if case .failed = result { return }
        }

        // Cancel any existing timer
        sleepTimer?.invalidate()
        countdownTimer?.invalidate()

        // Set the end date and start timers
        timerEndDate = Date().addingTimeInterval(seconds)

        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.timerFired()
        }

        // Update the countdown display every second
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }

        updateMenu()
    }

    @objc private func cancelScheduledSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        timerEndDate = nil
        updateMenu()
    }

    private func timerFired() {
        sleepTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        timerEndDate = nil

        // Re-enable sleep
        if sleepToggle.isDisableSleep {
            _ = sleepToggle.toggle()
        }
        // Clamshell Mode도 타이머 만료 시 함께 해제 (끄는 걸 잊는 리스크 방지)
        if clamshellMode.isOn {
            clamshellMode.set(false)
        }
        updateMenu()
    }

    @objc private func toggleSleep() {
        let result = sleepToggle.toggle()
        switch result {
        case .success:
            cancelScheduledSleep()
            updateMenu()
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = "caffeinate failed: \(message)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 앱 종료 시 자식 caffeinate 정리 — 고아 프로세스가 보이지 않게 sleep을 계속 막는 것 방지
        if sleepToggle.isDisableSleep {
            _ = sleepToggle.toggle()
        }
        // 커널 disablesleep도 원복 — 앱이 없으면 끌 수단이 사라지므로 반드시 해제
        if clamshellMode.isOn {
            clamshellMode.set(false)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        sleepToggle.refresh()
        clamshellMode.refresh()
        updateMenu()
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
