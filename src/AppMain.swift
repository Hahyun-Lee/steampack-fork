import Cocoa
import ServiceManagement
import WidgetKit
import IOKit.ps

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

    // Control Center 토글의 "켜짐" 의도 (전원 변경 시 알맞은 방식으로 재적용하기 위함)
    private var keepAwakeDesired = false
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        updateIcon()

        registerControlObserver()      // Control Center 토글 → 앱 수신
        registerPowerSourceObserver()  // 전원(AC↔배터리) 변경 시 재적용
        publishState()                 // 현재 상태를 컨트롤에 반영
    }

    /// 현재 AC 어댑터 전원인지 (배터리면 false).
    private func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return true }   // 데스크톱 등 판별 불가 시 AC로 간주
        return type == kIOPMACPowerKey
    }

    /// 전원 소스 변경 알림 등록 — keep-awake가 켜져 있으면 새 전원에 맞게 재적용.
    private func registerPowerSourceObserver() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                if delegate.keepAwakeDesired { delegate.applyKeepAwake(true) }
            }
        }, ctx)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    /// 전원에 맞는 방식으로 keep-awake 적용:
    /// AC = caffeinate(부드럽게, 뚜껑 닫으면 잠), 배터리 = pmset disablesleep(뚜껑 닫아도 유지).
    func applyKeepAwake(_ on: Bool) {
        keepAwakeDesired = on
        if on {
            if onACPower() {
                if clamshellMode.isOn { clamshellMode.set(false) }      // 배터리용 해제
                if !sleepToggle.isDisableSleep { _ = sleepToggle.toggle() }
            } else {
                if sleepToggle.isDisableSleep { _ = sleepToggle.toggle() }  // AC용 해제
                let r = clamshellMode.set(true)
                if case .failed = r {                                    // sudoers 미설치 폴백
                    if !sleepToggle.isDisableSleep { _ = sleepToggle.toggle() }
                }
            }
        } else {
            if sleepToggle.isDisableSleep { _ = sleepToggle.toggle() }
            if clamshellMode.isOn { clamshellMode.set(false) }
        }
        updateMenu()
    }

    /// Control Widget이 보낸 Darwin "토글 요청"을 수신하도록 등록.
    private func registerControlObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { delegate.handleControlToggleRequest() }
            },
            SteamPackShared.toggleRequestName,
            nil,
            .deliverImmediately)
    }

    /// 컨트롤이 기록한 "원하는 상태"에 실제 상태를 맞춘다.
    /// 작업 후 publishState()가 실제 결과를 다시 컨트롤로 반영(자기 정정).
    func handleControlToggleRequest() {
        // perform()이 이미 새 desired 값을 파일에 기록함 → 그 값에 맞춰 실제 메커니즘 적용.
        let desired = SteamPackShared.readKeepAwake()
        cancelScheduledSleep()
        applyKeepAwake(desired)
    }

    /// 현재 sleep 억제 상태를 App Group에 기록하고 Control Center 컨트롤을 새로고침.
    func publishState() {
        let keepAwake = sleepToggle.isDisableSleep || clamshellMode.isOn
        keepAwakeDesired = keepAwake   // 메뉴 조작 포함 실제 상태와 동기화
        SteamPackShared.writeKeepAwake(keepAwake)
        ControlCenter.shared.reloadControls(ofKind: SteamPackShared.controlKind)
        // macOS Tahoe에서 즉시 reload가 누락되는 경우 대비 — 짧은 지연 후 재호출
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.controlKind)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.controlKind)
        }
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
        publishState()  // Control Center 컨트롤 상태 동기화
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
