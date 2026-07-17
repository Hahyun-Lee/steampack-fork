import Cocoa
import ServiceManagement
import WidgetKit

enum SteamPackRuntimeRefreshPolicy {
    static let heartbeatInterval: TimeInterval = 2
    static let fullStateInterval: TimeInterval = 10

    static func shouldPersistRuntimeChange(
        from previous: SteamPackControlPolicy.DesiredMode,
        to current: SteamPackControlPolicy.DesiredMode
    ) -> Bool {
        previous != current
    }

    static func shouldCancelAutoOff(
        after mode: SteamPackControlPolicy.DesiredMode
    ) -> Bool {
        mode == .normalSleep
    }
}

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
    private var stateRefreshTimer: Timer?
    private var lastSafetyEvent: String?
    private var localIntentBarrier = SteamPackLocalIntentBarrier()
    private var lastAcceptedControlRevision: UInt64 = 0
    private var localIntentRetryWorkItem: DispatchWorkItem?
    private var localIntentPersistenceFailed = false
    private var appliedStatePersistenceFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableSuddenTermination()
        // Never let a still-fresh marker from a prior crash make Control Center
        // revive that process's last applied state during launch initialization.
        SteamPackShared.clearHeartbeat()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        registerControlObservers()
        configureSafety()
        lastAcceptedControlRevision = SteamPackShared.readControlRequest().revision
        syncLocalControlIntent()
        startStatePublishing()

        clamshellMode.onWatchdogFailure = { [weak self] restored in
            guard let self else { return }
            self.lastSafetyEvent = restored
                ? SteamPackL10n.text("Watchdog stopped — normal sleep restored")
                : SteamPackL10n.text("Watchdog stopped — normal sleep could not be restored")
            self.cancelAutoOffIfRuntimeIsNormal()
            self.syncLocalControlIntent()
            if restored {
                PowerSafetyNotifier.notifyWatchdogFailure()
            } else {
                PowerSafetyNotifier.notifyWatchdogRestoreFailure()
            }
            self.updateMenu()
        }
        sleepToggle.onStateChange = { [weak self] in
            guard let self else { return }
            self.cancelAutoOffIfRuntimeIsNormal()
            self.syncLocalControlIntent()
            self.updateMenu()
        }

        safetyMonitor.start()
        updateMenu()
    }

    // MARK: - Control Center

    func onKeepAwakeRequest() {
        reconcileControlRequests()
    }

    func onClamshellRequest() {
        reconcileControlRequests()
    }

    private func reconcileControlRequests() {
        // Notifications carry no payload. Reading one atomically replaced record
        // means even an older notification delivered late reconciles the newest
        // complete request, never a mix of two requests.
        let request = SteamPackShared.readControlRequest()
        defer { finishControlReconciliation(requestedRevision: request.revision) }
        let resolution = localIntentBarrier.resolve(request)
        if resolution.acceptedIncomingRequest {
            lastAcceptedControlRevision = max(lastAcceptedControlRevision, request.revision)
            localIntentRetryWorkItem?.cancel()
            localIntentRetryWorkItem = nil
            localIntentPersistenceFailed = false
        }
        let desiredMode = resolution.mode

        switch desiredMode {
        case .normalSleep:
            let report = stopAllKeepAwakeModes()
            cancelAutoOffIfRuntimeIsNormal()
            report.failures.forEach(PowerSafetyNotifier.notifyControlFailure)

        case .keepAwake:
            if clamshellMode.isOn {
                let result = clamshellMode.set(false)
                if case .failed(let message) = result {
                    PowerSafetyNotifier.notifyControlFailure(message)
                    return
                }
            }
            if !sleepToggle.isDisableSleep,
               case .failed(let message) = sleepToggle.toggle() {
                cancelAutoOffIfRuntimeIsNormal()
                PowerSafetyNotifier.notifyControlFailure(message)
            }

        case .closedLid:
            switch enableClamshell() {
            case .success:
                break
            case .failed(let message):
                PowerSafetyNotifier.notifyControlFailure(message)
            }
        }
    }

    private func finishControlReconciliation(requestedRevision: UInt64) {
        updateMenu()
        guard SteamPackShared.readControlRequest().revision > requestedRevision else { return }
        // A newer request arrived while the older one was being applied. Reconcile
        // it even if Darwin notifications were coalesced or delivered out of order.
        DispatchQueue.main.async { [weak self] in
            self?.reconcileControlRequests()
        }
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

    private func startStatePublishing() {
        publishState(reloadControls: false)
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: SteamPackRuntimeRefreshPolicy.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.publishState(reloadControls: false)
        }
        stateRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: SteamPackRuntimeRefreshPolicy.fullStateInterval,
            repeats: true
        ) { [weak self] _ in
            self?.periodicFullStateRefresh()
        }
    }

    private func periodicFullStateRefresh() {
        refreshRuntimeState()
        safetyMonitor.refresh()
        updateMenu(refreshRuntimeState: false)
    }

    private func refreshRuntimeState() {
        let previousMode = currentRuntimeMode()
        sleepToggle.refresh()
        clamshellMode.refresh()
        let currentMode = currentRuntimeMode()
        guard SteamPackRuntimeRefreshPolicy.shouldPersistRuntimeChange(
            from: previousMode,
            to: currentMode
        ) else { return }

        if SteamPackRuntimeRefreshPolicy.shouldCancelAutoOff(after: currentMode) {
            cancelTimerWithoutUpdating()
        }
        // An external pmset change or component exit is authoritative. Persist
        // the complete post-refresh mode before a delayed/coalesced Control
        // Center notification can read and replay an older request. Comparing
        // modes (not just aggregate ON/OFF) also covers Closed Lid -> Keep Awake.
        persistLocalIntent(currentMode)
    }

    private func publishState(reloadControls: Bool = true) {
        let published = SteamPackShared.publishApplied(
            keepAwake: sleepToggle.isDisableSleep || clamshellMode.isOn,
            clamshell: clamshellMode.isOn
        )
        handleAppliedStatePublication(published)
        guard reloadControls else { return }
        reloadControlCenterState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reloadControlCenterState()
        }
    }

    private func reloadControlCenterState() {
        // Per-kind reloads target both controls; reloadAllControls is the
        // strongest additional invalidation API exposed by WidgetKit for
        // Control Widgets. WidgetCenter timeline reloads apply to widgets, not
        // ControlValueProvider state, so they are intentionally not used here.
        ControlCenter.shared.reloadControls(ofKind: SteamPackShared.keepAwakeKind)
        ControlCenter.shared.reloadControls(ofKind: SteamPackShared.clamshellKind)
        ControlCenter.shared.reloadAllControls()
    }

    private func handleAppliedStatePublication(_ succeeded: Bool) {
        if succeeded {
            guard appliedStatePersistenceFailed else { return }
            appliedStatePersistenceFailed = false
            updateSafetyMenuItem()
            updateIcon()
            return
        }

        if !appliedStatePersistenceFailed {
            appliedStatePersistenceFailed = true
            PowerSafetyNotifier.notifyControlFailure(SteamPackL10n.text(
                "SteamPack could not publish its applied state. Control Center may be stale; the app will retry."
            ))
        }
        updateSafetyMenuItem()
        updateIcon()
    }

    // MARK: - Safety

    private func configureSafety() {
        safetyMonitor.onUpdate = { [weak self] _ in
            self?.updateSafetyMenuItem()
        }
        safetyMonitor.onUnsafe = { [weak self] issue in
            guard let self, self.clamshellMode.isOn else { return }
            self.recordLocalOffIntent()
            let result = self.clamshellMode.set(false)
            if case .failed(let message) = result {
                self.lastSafetyEvent = SteamPackL10n.text(
                    "Safety could not restore normal sleep"
                )
                PowerSafetyNotifier.notifyControlFailure(message)
                self.updateMenu()
                return
            }
            self.cancelAutoOffIfRuntimeIsNormal()
            self.syncLocalControlIntent()
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

    @discardableResult
    private func stopAllKeepAwakeModes() -> SteamPackStopReport {
        var attempts: [SteamPackStopAttempt] = []
        if sleepToggle.isDisableSleep {
            switch sleepToggle.toggle() {
            case .success: attempts.append(.success)
            case .failed(let message): attempts.append(.failed(message))
            }
        }
        if clamshellMode.isOn {
            switch clamshellMode.set(false) {
            case .success: attempts.append(.success)
            case .failed(let message): attempts.append(.failed(message))
            }
        }
        return SteamPackStopReport(attempts: attempts)
    }

    @discardableResult
    private func syncLocalControlIntent() -> Bool {
        persistLocalIntent(currentRuntimeMode())
    }

    private func currentRuntimeMode() -> SteamPackControlPolicy.DesiredMode {
        if clamshellMode.isOn {
            return .closedLid
        } else if sleepToggle.isDisableSleep {
            return .keepAwake
        }
        return .normalSleep
    }

    private func cancelAutoOffIfRuntimeIsNormal() {
        if SteamPackRuntimeRefreshPolicy.shouldCancelAutoOff(
            after: currentRuntimeMode()
        ) {
            cancelTimerWithoutUpdating()
        }
    }

    @discardableResult
    private func recordLocalOffIntent() -> Bool {
        persistLocalIntent(.normalSleep)
    }

    @discardableResult
    private func persistLocalIntent(
        _ mode: SteamPackControlPolicy.DesiredMode
    ) -> Bool {
        let currentRequest = SteamPackShared.readControlRequest()
        let protectedRevision = max(
            lastAcceptedControlRevision,
            currentRequest.revision
        )
        localIntentBarrier.begin(mode, throughRevision: protectedRevision)

        switch writeLocalIntent(mode, ifCurrentRevisionAtMost: protectedRevision) {
        case .written(let persisted):
            _ = localIntentBarrier.markPersisted(persisted)
            lastAcceptedControlRevision = max(lastAcceptedControlRevision, persisted.revision)
            localIntentRetryWorkItem?.cancel()
            localIntentRetryWorkItem = nil
            localIntentPersistenceFailed = false
            return true
        case .conflict(let newerRequest):
            acceptNewerControlRequest(newerRequest)
            return false
        case .failed:
            handleLocalIntentPersistenceFailure()
            return false
        }
    }

    private func writeLocalIntent(
        _ mode: SteamPackControlPolicy.DesiredMode,
        ifCurrentRevisionAtMost maximumRevision: UInt64
    ) -> SteamPackControlWriteResult {
        switch mode {
        case .normalSleep:
            return SteamPackShared.compareAndResetControlRequest(
                keepAwake: false,
                clamshell: false,
                ifCurrentRevisionAtMost: maximumRevision
            )
        case .keepAwake:
            return SteamPackShared.compareAndResetControlRequest(
                keepAwake: true,
                clamshell: false,
                ifCurrentRevisionAtMost: maximumRevision
            )
        case .closedLid:
            return SteamPackShared.compareAndResetControlRequest(
                keepAwake: true,
                clamshell: true,
                ifCurrentRevisionAtMost: maximumRevision
            )
        }
    }

    private func handleLocalIntentPersistenceFailure() {
        if !localIntentPersistenceFailed {
            localIntentPersistenceFailed = true
            PowerSafetyNotifier.notifyControlFailure(SteamPackL10n.text(
                "SteamPack could not save the requested state. The app will retry."
            ))
        }
        scheduleLocalIntentPersistenceRetry()
    }

    private func scheduleLocalIntentPersistenceRetry() {
        localIntentRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryLocalIntentPersistence()
        }
        localIntentRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func retryLocalIntentPersistence() {
        localIntentRetryWorkItem = nil
        guard let pending = localIntentBarrier.pendingIntent else { return }

        switch writeLocalIntent(
            pending.mode,
            ifCurrentRevisionAtMost: pending.throughRevision
        ) {
        case .written(let persisted):
            _ = localIntentBarrier.markPersisted(persisted)
            lastAcceptedControlRevision = max(lastAcceptedControlRevision, persisted.revision)
            localIntentPersistenceFailed = false
            updateMenu()
        case .conflict(let newerRequest):
            acceptNewerControlRequest(newerRequest)
        case .failed:
            handleLocalIntentPersistenceFailure()
            updateMenu()
        }
    }

    private func acceptNewerControlRequest(_ request: SteamPackControlRequest) {
        let resolution = localIntentBarrier.resolve(request)
        guard resolution.acceptedIncomingRequest else { return }
        lastAcceptedControlRevision = max(lastAcceptedControlRevision, request.revision)
        localIntentRetryWorkItem?.cancel()
        localIntentRetryWorkItem = nil
        localIntentPersistenceFailed = false
        DispatchQueue.main.async { [weak self] in
            self?.reconcileControlRequests()
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

    private func updateMenu(refreshRuntimeState: Bool = true) {
        if refreshRuntimeState {
            self.refreshRuntimeState()
        }
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
        if localIntentPersistenceFailed {
            safetyMenuItem.title = "⚠ " + SteamPackL10n.text(
                "Requested state could not be saved — retrying"
            )
            return
        }
        if appliedStatePersistenceFailed {
            safetyMenuItem.title = "⚠ " + SteamPackL10n.text(
                "Applied state could not be published — retrying"
            )
            return
        }

        let snapshot = safetyMonitor.snapshot
        let power: String
        switch snapshot.powerConnection {
        case .acPower:
            power = SteamPackL10n.text("AC power")
        case .battery:
            if let percent = snapshot.batteryPercent {
                power = SteamPackL10n.format("Battery %d%%", percent)
            } else {
                power = SteamPackL10n.text("Battery level unknown")
            }
        case .unknown:
            power = SteamPackL10n.text("Power source unknown")
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
        if clamshellMode.isSystemStatusUnknown {
            return SteamPackL10n.text("Could not verify the macOS sleep setting")
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
        if lastSafetyEvent != nil
            || localIntentPersistenceFailed
            || appliedStatePersistenceFailed {
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
            recordLocalOffIntent()
            let report = stopAllKeepAwakeModes()
            if !report.failures.isEmpty {
                showAlert(
                    title: SteamPackL10n.text("Keep Awake"),
                    message: report.failures.joined(separator: "\n")
                )
            }
        } else {
            switch sleepToggle.toggle() {
            case .success:
                syncLocalControlIntent()
            case .failed(let message):
                showAlert(title: SteamPackL10n.text("Keep Awake"), message: message)
            }
        }
        updateMenu()
    }

    @objc private func toggleClamshell() {
        lastSafetyEvent = nil
        cancelTimerWithoutUpdating()
        let wasOn = clamshellMode.isOn
        if wasOn { recordLocalOffIntent() }
        let result = wasOn ? clamshellMode.set(false) : enableClamshell()
        if case .failed(let message) = result {
            showAlert(title: SteamPackL10n.text("Closed-Lid Mode"), message: message)
        } else if !wasOn {
            syncLocalControlIntent()
        }
        updateMenu()
    }

    @objc private func toggleClamshellAuthorization() {
        if clamshellMode.isAuthorized {
            if clamshellMode.isOn {
                recordLocalOffIntent()
                if case .failed(let message) = clamshellMode.set(false) {
                    showAlert(title: SteamPackL10n.text("Closed-Lid Permission"), message: message)
                    return
                }
                cancelAutoOffIfRuntimeIsNormal()
                syncLocalControlIntent()
                // The permission confirmation can still be cancelled, but Closed
                // Lid has already been turned off successfully and its OFF intent
                // was recorded before changing the system setting.
            }
            let alert = NSAlert()
            alert.messageText = SteamPackL10n.text("Remove Closed-Lid permission?")
            alert.informativeText = SteamPackL10n.text(
                "Keep Awake will continue to work, but closed-lid mode will be unavailable."
            )
            alert.addButton(withTitle: SteamPackL10n.text("Remove"))
            alert.addButton(withTitle: SteamPackL10n.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                updateMenu()
                return
            }
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
            if case .failed(let message) = sleepToggle.toggle() {
                showAlert(title: SteamPackL10n.text("Auto-Off Timer"), message: message)
                return
            }
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
        syncLocalControlIntent()
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
        recordLocalOffIntent()
        let report = stopAllKeepAwakeModes()
        if !report.failures.isEmpty {
            report.failures.forEach(PowerSafetyNotifier.notifyControlFailure)
        }
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
        stateRefreshTimer?.invalidate()
        safetyMonitor.stop()
        cancelTimerWithoutUpdating()
        let report = stopAllKeepAwakeModes()
        report.failures.forEach(PowerSafetyNotifier.notifyControlFailure)
        _ = recordLocalOffIntent()
        localIntentRetryWorkItem?.cancel()
        localIntentRetryWorkItem = nil
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        SteamPackShared.clearHeartbeat()
        // Graceful termination can explicitly invalidate visible Control
        // Center state. A crash cannot execute this path and remains part of
        // the required installed-build E2E matrix.
        reloadControlCenterState()
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
