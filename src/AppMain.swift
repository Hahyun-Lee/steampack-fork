import Cocoa
import ServiceManagement
import WidgetKit

enum SteamPackRuntimeRefreshPolicy {
    static let heartbeatInterval: TimeInterval = 2
    static let fullStateInterval: TimeInterval = 10
    static let controlReloadRetryDelay: TimeInterval = 0.5

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

struct SteamPackControlSurfaceState: Equatable {
    let keepAwake: Bool
    let clamshell: Bool

    init(keepAwake: Bool, clamshell: Bool) {
        self.keepAwake = keepAwake || clamshell
        self.clamshell = clamshell
    }

    func changedControls(
        comparedTo previous: SteamPackControlSurfaceState?
    ) -> SteamPackControlReloadDecision {
        guard let previous else { return .both }
        return SteamPackControlReloadDecision(
            keepAwake: keepAwake != previous.keepAwake,
            clamshell: clamshell != previous.clamshell
        )
    }
}

struct SteamPackControlReloadDecision: Equatable {
    let keepAwake: Bool
    let clamshell: Bool

    static let none = SteamPackControlReloadDecision(
        keepAwake: false,
        clamshell: false
    )
    static let both = SteamPackControlReloadDecision(
        keepAwake: true,
        clamshell: true
    )

    static func decide(
        publicationSucceeded: Bool,
        publicationWasInvalid: Bool,
        reloadStateChanges: Bool,
        previous: SteamPackControlSurfaceState?,
        current: SteamPackControlSurfaceState
    ) -> SteamPackControlReloadDecision {
        if !publicationSucceeded {
            return publicationWasInvalid ? .none : .both
        }
        if publicationWasInvalid {
            return .both
        }
        guard reloadStateChanges else { return .none }
        return current.changedControls(comparedTo: previous)
    }

    func suppressingAutomaticReload(
        for channel: SteamPackControlChannel?
    ) -> SteamPackControlReloadDecision {
        switch channel {
        case .keepAwake:
            return SteamPackControlReloadDecision(
                keepAwake: false,
                clamshell: clamshell
            )
        case .clamshell:
            return SteamPackControlReloadDecision(
                keepAwake: keepAwake,
                clamshell: false
            )
        case nil:
            return self
        }
    }
}

struct SteamPackControlReloadRetryToken: Equatable {
    let channel: SteamPackControlChannel
    let expectedValue: Bool
    let generation: UInt64
}

struct SteamPackControlReloadRetryUpdate: Equatable {
    let cancelled: SteamPackControlReloadDecision
    let keepAwakeToken: SteamPackControlReloadRetryToken?
    let clamshellToken: SteamPackControlReloadRetryToken?
}

struct SteamPackControlReloadRetryState {
    private var keepAwakeToken: SteamPackControlReloadRetryToken?
    private var clamshellToken: SteamPackControlReloadRetryToken?
    private var nextGeneration: UInt64 = 0

    mutating func update(
        for state: SteamPackControlSurfaceState,
        scheduling decision: SteamPackControlReloadDecision
    ) -> SteamPackControlReloadRetryUpdate {
        let cancelKeepAwake = keepAwakeToken.map {
            $0.expectedValue != state.keepAwake
        } ?? false
        let cancelClamshell = clamshellToken.map {
            $0.expectedValue != state.clamshell
        } ?? false

        if cancelKeepAwake {
            keepAwakeToken = nil
        }
        if cancelClamshell {
            clamshellToken = nil
        }

        var scheduledKeepAwake: SteamPackControlReloadRetryToken?
        if decision.keepAwake, keepAwakeToken == nil {
            scheduledKeepAwake = makeToken(
                channel: .keepAwake,
                expectedValue: state.keepAwake
            )
            keepAwakeToken = scheduledKeepAwake
        }

        var scheduledClamshell: SteamPackControlReloadRetryToken?
        if decision.clamshell, clamshellToken == nil {
            scheduledClamshell = makeToken(
                channel: .clamshell,
                expectedValue: state.clamshell
            )
            clamshellToken = scheduledClamshell
        }

        return SteamPackControlReloadRetryUpdate(
            cancelled: SteamPackControlReloadDecision(
                keepAwake: cancelKeepAwake,
                clamshell: cancelClamshell
            ),
            keepAwakeToken: scheduledKeepAwake,
            clamshellToken: scheduledClamshell
        )
    }

    func pendingToken(
        for channel: SteamPackControlChannel
    ) -> SteamPackControlReloadRetryToken? {
        switch channel {
        case .keepAwake:
            return keepAwakeToken
        case .clamshell:
            return clamshellToken
        }
    }

    mutating func consume(_ token: SteamPackControlReloadRetryToken) -> Bool {
        switch token.channel {
        case .keepAwake:
            guard keepAwakeToken == token else { return false }
            keepAwakeToken = nil
        case .clamshell:
            guard clamshellToken == token else { return false }
            clamshellToken = nil
        }
        return true
    }

    mutating func cancelAll() {
        keepAwakeToken = nil
        clamshellToken = nil
    }

    private mutating func makeToken(
        channel: SteamPackControlChannel,
        expectedValue: Bool
    ) -> SteamPackControlReloadRetryToken {
        nextGeneration &+= 1
        return SteamPackControlReloadRetryToken(
            channel: channel,
            expectedValue: expectedValue,
            generation: nextGeneration
        )
    }
}

enum SteamPackKeepAwakeTransitionStep: Equatable {
    case startKeepAwake
    case disableClosedLid
}

enum SteamPackKeepAwakeTransitionPlan {
    static func steps(
        keepAwakeIsOn: Bool,
        closedLidIsOn: Bool
    ) -> [SteamPackKeepAwakeTransitionStep] {
        var result: [SteamPackKeepAwakeTransitionStep] = []
        if !keepAwakeIsOn {
            result.append(.startKeepAwake)
        }
        if closedLidIsOn {
            result.append(.disableClosedLid)
        }
        return result
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
    private var keepAwakeReloadRetryWorkItem: DispatchWorkItem?
    private var clamshellReloadRetryWorkItem: DispatchWorkItem?
    private var controlReloadRetryState = SteamPackControlReloadRetryState()
    private var appliedStateExpiryReloadWorkItem: DispatchWorkItem?
    private var localIntentPersistenceFailed = false
    private var appliedStatePersistenceFailed = false
    private var lastPublishedControlState: SteamPackControlSurfaceState?
    private var lastControlAcknowledgement: SteamPackControlAcknowledgement?

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
        // A Darwin notification is only a wake hint and may be duplicated. The
        // revision gate guarantees that an already-handled request cannot run
        // the actuator or its verification path twice.
        guard request.revision > lastAcceptedControlRevision else { return }
        if request.isExpired() {
            // A control intent may already have returned an error. A request that
            // reaches the app after its deadline is acknowledged as rejected but
            // must never actuate later in the background.
            lastAcceptedControlRevision = request.revision
            lastControlAcknowledgement = SteamPackControlAcknowledgement.evaluate(
                request: request,
                acceptedIncomingRequest: false,
                appliedKeepAwake: sleepToggle.isDisableSleep,
                appliedClamshell: clamshellMode.isOn
            )
            if localIntentBarrier.extendPendingIntent(
                throughRevision: request.revision
            ) {
                // Preserve a newer local safety/menu decision above the expired
                // record so a restart cannot rediscover it as the current intent.
                scheduleLocalIntentPersistenceRetry()
            }
            publishState(automaticReloadChannel: nil)
            requestControlCenterReload(.both)
            updateMenu(
                refreshRuntimeState: false,
                publishControlState: false
            )
            return
        }
        let resolution = localIntentBarrier.resolve(request)
        lastAcceptedControlRevision = max(lastAcceptedControlRevision, request.revision)
        if resolution.acceptedIncomingRequest {
            localIntentRetryWorkItem?.cancel()
            localIntentRetryWorkItem = nil
            localIntentPersistenceFailed = false
        } else {
            // The pending local intent is authoritative. Mark this revision as
            // terminally rejected, then persist the local mode above it.
            lastControlAcknowledgement = SteamPackControlAcknowledgement.evaluate(
                request: request,
                acceptedIncomingRequest: false,
                appliedKeepAwake: sleepToggle.isDisableSleep,
                appliedClamshell: clamshellMode.isOn
            )
            _ = localIntentBarrier.extendPendingIntent(
                throughRevision: request.revision
            )
            scheduleLocalIntentPersistenceRetry()
        }
        applyControlMode(resolution.mode)
        finishControlReconciliation(
            requestedRequest: request,
            acceptedIncomingRequest: resolution.acceptedIncomingRequest
        )
    }

    private func applyControlMode(_ desiredMode: SteamPackControlPolicy.DesiredMode) {
        switch desiredMode {
        case .normalSleep:
            let report = stopAllKeepAwakeModes()
            cancelAutoOffIfRuntimeIsNormal()
            report.failures.forEach(PowerSafetyNotifier.notifyControlFailure)

        case .keepAwake:
            if let failure = transitionToKeepAwake() {
                cancelAutoOffIfRuntimeIsNormal()
                PowerSafetyNotifier.notifyControlFailure(failure)
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

    @discardableResult
    private func transitionToKeepAwake() -> String? {
        let steps = SteamPackKeepAwakeTransitionPlan.steps(
            keepAwakeIsOn: sleepToggle.isDisableSleep,
            closedLidIsOn: clamshellMode.isOn
        )
        var startedKeepAwake = false

        for step in steps {
            switch step {
            case .startKeepAwake:
                switch sleepToggle.toggle() {
                case .success:
                    startedKeepAwake = true
                case .failed(let message):
                    return message
                }

            case .disableClosedLid:
                let result = clamshellMode.set(false)
                if case .failed(let message) = result {
                    // Preserve the mode that existed before this transition. A
                    // newly started caffeinate process is compensation-only and
                    // must not remain after pmset failed to turn off.
                    if startedKeepAwake, sleepToggle.isDisableSleep {
                        _ = sleepToggle.toggle()
                    }
                    return message
                }
            }
        }
        return nil
    }

    private func finishControlReconciliation(
        requestedRequest: SteamPackControlRequest,
        acceptedIncomingRequest: Bool
    ) {
        let newestRequest = SteamPackShared.readControlRequest()
        if newestRequest.revision > requestedRequest.revision {
            // Do not publish an intermediate acknowledgement after a rapid tap
            // or timeout rollback. Apply the newest complete record first.
            reconcileControlRequests()
            return
        }

        // Use one verification instant for both deadline evaluation and the
        // durable acknowledgement timestamp. The mode may be fully applied just
        // before the deadline even if the atomic file replacement finishes a few
        // milliseconds later.
        let verificationTime = Date()
        let expiredDuringActuation = acceptedIncomingRequest
            && requestedRequest.isExpired(now: verificationTime)
        if expiredDuringActuation {
            // A slow pmset/watchdog path crossed the intent deadline. Restore the
            // captured pre-request mode before publishing a terminal rejection.
            applyControlMode(requestedRequest.rollbackMode)
        }
        let publicationTime = expiredDuringActuation ? Date() : verificationTime
        lastControlAcknowledgement = SteamPackControlAcknowledgement.evaluate(
            request: requestedRequest,
            acceptedIncomingRequest: acceptedIncomingRequest
                && !expiredDuringActuation,
            appliedKeepAwake: sleepToggle.isDisableSleep,
            appliedClamshell: clamshellMode.isOn,
            now: verificationTime
        )
        var requestSucceeded = lastControlAcknowledgement?.succeeded == true
        // Persist the verified actuator result and request revision before the
        // intent returns and Control Center performs its automatic value query.
        // Menu rendering and safety copy are not on the acknowledgement path.
        let acknowledgementPublished = publishState(
            automaticReloadChannel: requestSucceeded
                ? requestedRequest.source
                : nil,
            now: publicationTime
        )
        if requestSucceeded, !acknowledgementPublished {
            // Never leave an applied mode paired with an intent that cannot see
            // its durable success. Restore the captured mode immediately and make
            // the terminal outcome a rejection for every later heartbeat.
            applyControlMode(requestedRequest.rollbackMode)
            let rollbackTime = Date()
            lastControlAcknowledgement = SteamPackControlAcknowledgement.evaluate(
                request: requestedRequest,
                acceptedIncomingRequest: false,
                appliedKeepAwake: sleepToggle.isDisableSleep,
                appliedClamshell: clamshellMode.isOn,
                now: rollbackTime
            )
            requestSucceeded = false
            _ = publishState(
                automaticReloadChannel: nil,
                now: rollbackTime
            )
        }
        if !requestSucceeded {
            requestControlCenterReload(.both)
        }
        updateMenu(
            refreshRuntimeState: false,
            publishControlState: false
        )
        guard SteamPackShared.readControlRequest().revision
                > requestedRequest.revision else { return }
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
        // A prior process can leave a cached ON tile behind after a crash. The
        // first durable state of this launch must actively replace that cache;
        // later heartbeats remain silent when the state is unchanged.
        publishState(reloadControls: true)
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: SteamPackRuntimeRefreshPolicy.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            if !self.reconcilePendingControlRequestIfNeeded() {
                self.publishState(reloadControls: false)
            }
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

    @discardableResult
    private func publishState(
        reloadControls: Bool = true,
        automaticReloadChannel: SteamPackControlChannel? = nil,
        now: Date = Date()
    ) -> Bool {
        let controlState = SteamPackControlSurfaceState(
            keepAwake: sleepToggle.isDisableSleep,
            clamshell: clamshellMode.isOn
        )
        let publicationWasInvalid = appliedStatePersistenceFailed
        let currentRequest = SteamPackShared.readControlRequest()
        let currentAcknowledgement = lastControlAcknowledgement.flatMap {
            $0.requestRevision == lastAcceptedControlRevision
                && currentRequest.revision == $0.requestRevision
                ? $0
                : nil
        }
        let published = SteamPackShared.publishApplied(
            keepAwake: controlState.keepAwake,
            clamshell: controlState.clamshell,
            requestRevision: lastAcceptedControlRevision,
            requestSource: currentAcknowledgement?.source,
            requestSucceeded: currentAcknowledgement?.succeeded,
            now: now
        )
        handleAppliedStatePublication(published)
        let reloadDecision = SteamPackControlReloadDecision.decide(
            publicationSucceeded: published,
            publicationWasInvalid: publicationWasInvalid,
            reloadStateChanges: reloadControls,
            previous: lastPublishedControlState,
            current: controlState
        ).suppressingAutomaticReload(for: automaticReloadChannel)
        requestControlCenterReload(reloadDecision)
        if published {
            // This tracks durable publication, not whether WidgetKit accepted a
            // reload request. Heartbeats and auto-reloaded source controls still
            // establish the comparison base for the next real state change.
            lastPublishedControlState = controlState
            // Reconcile each retry independently. A rapid Closed Lid ON -> OFF
            // transition changes only the Closed Lid value; the Keep Awake value
            // remains ON and must retain the retry created by the first action.
            // For a Control Center action, `reloadDecision` already suppresses
            // the tapped source because macOS reloads it after `perform()`.
            updateControlCenterReloadRetries(
                scheduling: reloadControls ? reloadDecision : .none,
                for: controlState
            )
        } else {
            // Never let a delayed retry advertise a value that the app could not
            // durably publish. The prior record is left in place so this main-
            // thread path cannot wedge in unlink; its timestamp fails closed at
            // appliedStateMaxAge. The first failure reloads both controls, and
            // recovery reloads both again even if the Booleans match the last
            // durable publication.
            cancelControlCenterReloadRetries()
            lastPublishedControlState = nil
        }
        return published
    }

    private func requestControlCenterReload(
        _ decision: SteamPackControlReloadDecision
    ) {
        if decision.keepAwake {
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.keepAwakeKind)
        }
        if decision.clamshell {
            ControlCenter.shared.reloadControls(ofKind: SteamPackShared.clamshellKind)
        }
    }

    private func updateControlCenterReloadRetries(
        scheduling decision: SteamPackControlReloadDecision,
        for state: SteamPackControlSurfaceState
    ) {
        let update = controlReloadRetryState.update(
            for: state,
            scheduling: decision
        )

        if update.cancelled.keepAwake {
            keepAwakeReloadRetryWorkItem?.cancel()
            keepAwakeReloadRetryWorkItem = nil
        }
        if update.cancelled.clamshell {
            clamshellReloadRetryWorkItem?.cancel()
            clamshellReloadRetryWorkItem = nil
        }

        if let token = update.keepAwakeToken {
            keepAwakeReloadRetryWorkItem = makeControlCenterReloadRetry(
                token: token
            )
        }
        if let token = update.clamshellToken {
            clamshellReloadRetryWorkItem = makeControlCenterReloadRetry(
                token: token
            )
        }
    }

    private func makeControlCenterReloadRetry(
        token: SteamPackControlReloadRetryToken
    ) -> DispatchWorkItem {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.controlReloadRetryState.consume(token) else { return }

            switch token.channel {
            case .keepAwake:
                self.keepAwakeReloadRetryWorkItem = nil
            case .clamshell:
                self.clamshellReloadRetryWorkItem = nil
            }

            guard !self.appliedStatePersistenceFailed,
                  self.lastPublishedValue(for: token.channel)
                    == token.expectedValue else { return }
            // WidgetKit can mark a non-visible control as needing reload without
            // refreshing the tile that becomes visible a fraction of a second
            // later. One targeted retry closes that race without periodic reload
            // traffic or a whole-extension reload. The target-only comparison
            // intentionally ignores a sibling value that changed in the interim.
            self.requestControlCenterReload(
                SteamPackControlReloadDecision(
                    keepAwake: token.channel == .keepAwake,
                    clamshell: token.channel == .clamshell
                )
            )
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SteamPackRuntimeRefreshPolicy.controlReloadRetryDelay,
            execute: workItem
        )
        return workItem
    }

    private func lastPublishedValue(
        for channel: SteamPackControlChannel
    ) -> Bool? {
        switch channel {
        case .keepAwake:
            return lastPublishedControlState?.keepAwake
        case .clamshell:
            return lastPublishedControlState?.clamshell
        }
    }

    private func cancelControlCenterReloadRetries() {
        keepAwakeReloadRetryWorkItem?.cancel()
        keepAwakeReloadRetryWorkItem = nil
        clamshellReloadRetryWorkItem?.cancel()
        clamshellReloadRetryWorkItem = nil
        controlReloadRetryState.cancelAll()
    }

    @discardableResult
    private func reconcilePendingControlRequestIfNeeded() -> Bool {
        let request = SteamPackShared.readControlRequest()
        guard request.revision > lastAcceptedControlRevision else { return false }
        // Darwin notifications are the low-latency path. This heartbeat check
        // is a bounded fallback if a notification is coalesced or lost.
        reconcileControlRequests()
        return true
    }

    private func handleAppliedStatePublication(_ succeeded: Bool) {
        if succeeded {
            appliedStateExpiryReloadWorkItem?.cancel()
            appliedStateExpiryReloadWorkItem = nil
            guard appliedStatePersistenceFailed else { return }
            appliedStatePersistenceFailed = false
            updateSafetyMenuItem()
            updateIcon()
            return
        }

        if !appliedStatePersistenceFailed {
            appliedStatePersistenceFailed = true
            scheduleAppliedStateExpiryReload()
            PowerSafetyNotifier.notifyControlFailure(SteamPackL10n.text(
                "SteamPack could not publish its applied state. Control Center may be stale; the app will retry."
            ))
        }
        updateSafetyMenuItem()
        updateIcon()
    }

    private func scheduleAppliedStateExpiryReload() {
        guard appliedStateExpiryReloadWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appliedStateExpiryReloadWorkItem = nil
            guard self.appliedStatePersistenceFailed else { return }
            // If invalidation of the previous record also failed, it can remain
            // readable until its freshness window closes. Reload once after that
            // boundary so a cached ON tile cannot survive indefinitely.
            self.requestControlCenterReload(.both)
        }
        appliedStateExpiryReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SteamPackShared.appliedStateMaxAge + 0.25,
            execute: workItem
        )
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
        // A local menu, timer, watchdog, or external-system observation starts a
        // new authority chain. Do not carry a prior Control Center outcome into
        // the applied record for that local transition.
        lastControlAcknowledgement = nil
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
        guard request.revision > lastAcceptedControlRevision else { return }
        // Leave both the revision and local-intent barrier untouched until the
        // normal reconciliation path actually accepts and actuates this record.
        // Advancing the revision here would make that path skip the same request.
        localIntentRetryWorkItem?.cancel()
        localIntentRetryWorkItem = nil
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

    private func updateMenu(
        refreshRuntimeState: Bool = true,
        publishControlState: Bool = true
    ) {
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
        if publishControlState {
            publishState()
        }
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
        if wasOn {
            // Match the Control Center state machine: Closed Lid OFF returns
            // to Keep Awake. Keep Awake OFF is the single transition back to
            // normal sleep from either surface.
            persistLocalIntent(.keepAwake)
            if let message = transitionToKeepAwake() {
                syncLocalControlIntent()
                showAlert(
                    title: SteamPackL10n.text("Closed-Lid Mode"),
                    message: message
                )
            } else {
                syncLocalControlIntent()
            }
        } else {
            let result = enableClamshell()
            if case .failed(let message) = result {
                showAlert(
                    title: SteamPackL10n.text("Closed-Lid Mode"),
                    message: message
                )
            } else {
                syncLocalControlIntent()
            }
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
        clamshellMode.refreshAuthorization()
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
        cancelControlCenterReloadRetries()
        appliedStateExpiryReloadWorkItem?.cancel()
        appliedStateExpiryReloadWorkItem = nil
        safetyMonitor.stop()
        cancelTimerWithoutUpdating()
        let report = stopAllKeepAwakeModes()
        report.failures.forEach(PowerSafetyNotifier.notifyControlFailure)
        _ = recordLocalOffIntent()
        localIntentRetryWorkItem?.cancel()
        localIntentRetryWorkItem = nil
        SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: lastAcceptedControlRevision
        )
        SteamPackShared.clearHeartbeat()
        // Graceful termination can explicitly invalidate visible Control
        // Center state. A crash cannot execute this path and remains part of
        // the required installed-build E2E matrix.
        lastPublishedControlState = nil
        requestControlCenterReload(.both)
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
