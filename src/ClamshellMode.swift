import Foundation

private final class ClamshellWatchdogLease {
    let token: String
    let writeHandle: FileHandle
    var expectedExit = false

    init(token: String, writeHandle: FileHandle) {
        self.token = token
        self.writeHandle = writeHandle
    }
}

/// Closed-lid sleep prevention backed by the narrowly-scoped sudoers rule.
/// A mandatory watchdog owns a pipe lease and restores normal sleep when the
/// app exits, crashes, or is killed.
final class ClamshellMode {
    private(set) var isOn = false
    private(set) var isExternallyDisabled = false
    private(set) var isSystemStatusUnknown = false

    var onWatchdogFailure: ((Bool) -> Void)?

    private let ownershipStore: ClamshellOwnershipStore
    private var activeSessionToken: String?
    private var watchdogProcess: Process?
    private var watchdogLease: ClamshellWatchdogLease?

    init(ownershipStore: ClamshellOwnershipStore = .defaultStore()) {
        self.ownershipStore = ownershipStore
        refresh()
    }

    var isAuthorized: Bool {
        ClamshellAuthorization.isInstalled()
    }

    func refresh() {
        // Recovery may have been blocked at launch because the restricted sudo
        // rule was absent. Retry on refresh so reinstalling it in the same app
        // session can safely restore normal sleep using the retained lease.
        recoverStaleOwnedState()
        guard let systemDisabled = currentSystemStatus() else {
            // Do not erase ownership or enable another session while the global
            // setting cannot be observed reliably.
            isOn = activeSessionToken.map(ownershipStore.matches) ?? false
            isExternallyDisabled = false
            isSystemStatusUnknown = true
            return
        }
        isSystemStatusUnknown = false
        let ownedByThisSession = activeSessionToken.map(ownershipStore.matches) ?? false
        isOn = systemDisabled && ownedByThisSession
        isExternallyDisabled = systemDisabled && !ownedByThisSession

        if !systemDisabled, ownedByThisSession, let token = activeSessionToken {
            ownershipStore.clearIfMatching(token: token)
            stopWatchdog(token: token)
            activeSessionToken = nil
        }
    }

    func currentSystemStatus() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return Self.parseSystemStatus(output)
    }

    static func parseSystemStatus(_ output: String) -> Bool? {
        guard let match = output.range(
            of: #"SleepDisabled\s+([01])(?=\s|$)"#,
            options: .regularExpression
        ) else { return nil }
        return output[match].last == "1"
    }

    enum ToggleResult {
        case success
        case failed(String)
    }

    func toggle() -> ToggleResult {
        set(!isOn)
    }

    @discardableResult
    func set(_ enabled: Bool) -> ToggleResult {
        enabled ? enable() : disable()
    }

    private func enable() -> ToggleResult {
        // Re-observe immediately before acquiring a lease. A menu refresh is only
        // a snapshot; another process may change SleepDisabled before this click.
        refresh()
        guard !isOn else { return .success }
        if let failure = Self.enablePreflightFailure(
            systemStatusUnknown: isSystemStatusUnknown,
            externallyDisabled: isExternallyDisabled,
            authorized: isAuthorized
        ) {
            return .failed(failure)
        }

        // Every enable cycle gets a new token. The previous watchdog may still be
        // unwinding after EOF, but it can never match this replacement lease.
        let record = ClamshellSessionLease.makeRecord()
        let claimResult: ClamshellOwnershipStore.ClaimResult
        do {
            claimResult = try ownershipStore.claim(
                record,
                existingOwnerIsActive: { [self] existing in
                    Self.ownershipIsActivelyLeased(
                        record: existing,
                        owningProcessIsLive: ClamshellOwnershipStore
                            .belongsToCurrentProcess(existing),
                        currentProcessID: ProcessInfo.processInfo.processIdentifier,
                        activeSessionToken: activeSessionToken,
                        watchdogToken: watchdogLease?.token
                    )
                },
                systemSleepIsDisabled: currentSystemStatus,
                authorizationIsInstalled: { self.isAuthorized },
                restoreNormalSleep: { ClamshellWatchdog.runPMSet(enabled: false) }
            )
        } catch {
            return .failed(SteamPackL10n.format(
                "Could not create the crash-recovery lease: %@",
                error.localizedDescription
            ))
        }
        if let failure = Self.claimFailureMessage(claimResult) {
            return .failed(failure)
        }
        activeSessionToken = record.token

        guard startWatchdog(token: record.token) else {
            ownershipStore.clearIfMatching(token: record.token)
            activeSessionToken = nil
            return .failed(SteamPackL10n.text("The crash-recovery watchdog could not start."))
        }

        guard ClamshellWatchdog.runPMSet(enabled: true) else {
            ownershipStore.clearIfMatching(token: record.token)
            stopWatchdog(token: record.token)
            activeSessionToken = nil
            return .failed(SteamPackL10n.text("macOS rejected the sleep setting."))
        }

        isOn = true
        isExternallyDisabled = false
        return .success
    }

    static func enablePreflightFailure(
        systemStatusUnknown: Bool,
        externallyDisabled: Bool,
        authorized: Bool
    ) -> String? {
        if systemStatusUnknown {
            return SteamPackL10n.text(
                "Could not verify the macOS sleep setting. Closed Lid was not enabled."
            )
        }
        if externallyDisabled {
            return SteamPackL10n.text("Sleep is already disabled by another app or command.")
        }
        if !authorized {
            return SteamPackL10n.text("Closed-Lid permission is not installed.")
        }
        return nil
    }

    static func claimFailureMessage(
        _ result: ClamshellOwnershipStore.ClaimResult
    ) -> String? {
        switch result {
        case .acquired:
            return nil
        case .ownedByActiveSession:
            return SteamPackL10n.text(
                "Closed Lid is already controlled by another SteamPack session."
            )
        case .systemStatusUnknown:
            return SteamPackL10n.text(
                "Could not verify the macOS sleep setting. Closed Lid was not enabled."
            )
        case .externallyDisabled:
            return SteamPackL10n.text("Sleep is already disabled by another app or command.")
        case .recoveryAuthorizationRequired:
            return SteamPackL10n.text(
                "A previous Closed Lid session still needs recovery. Reinstall the Closed-Lid permission and try again."
            )
        case .recoveryFailed:
            return SteamPackL10n.text(
                "SteamPack could not safely recover the previous Closed Lid session."
            )
        }
    }

    private func disable() -> ToggleResult {
        guard isOn else { return .success }
        guard ClamshellWatchdog.runPMSet(enabled: false) else {
            return .failed(SteamPackL10n.text("macOS could not restore normal sleep."))
        }

        isOn = false
        isExternallyDisabled = false
        let token = activeSessionToken
        if let token {
            ownershipStore.clearIfMatching(token: token)
        }
        stopWatchdog(token: token)
        activeSessionToken = nil
        return .success
    }

    private func startWatchdog(token: String) -> Bool {
        guard watchdogProcess == nil,
              let executableURL = Bundle.main.executableURL else { return false }

        let lease = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            ClamshellWatchdog.argument,
            token,
            ownershipStore.url.path
        ]
        process.standardInput = lease
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let leaseState = ClamshellWatchdogLease(
            token: token,
            writeHandle: lease.fileHandleForWriting
        )
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let isCurrentSession = self.activeSessionToken == leaseState.token
                if isCurrentSession {
                    self.watchdogProcess = nil
                    self.watchdogLease = nil
                }
                guard !leaseState.expectedExit, isCurrentSession, self.isOn else { return }

                // A Clamshell session without a watchdog is never allowed to continue.
                let restored = ClamshellWatchdog.restoreIfOwned(
                    token: leaseState.token,
                    store: self.ownershipStore
                ) {
                    ClamshellWatchdog.runPMSet(enabled: false)
                }
                self.isOn = false
                self.isExternallyDisabled = !restored
                self.activeSessionToken = nil
                self.onWatchdogFailure?(restored)
            }
        }

        do {
            try process.run()
            lease.fileHandleForReading.closeFile()
            watchdogProcess = process
            watchdogLease = leaseState
            return true
        } catch {
            lease.fileHandleForReading.closeFile()
            lease.fileHandleForWriting.closeFile()
            return false
        }
    }

    private func stopWatchdog(token: String? = nil) {
        guard let lease = watchdogLease else {
            watchdogProcess = nil
            return
        }
        if let token, lease.token != token { return }
        lease.expectedExit = true
        lease.writeHandle.closeFile()
        watchdogLease = nil
        // Release the old process immediately so a new enable cycle can start its
        // own watchdog without waiting for the old child to finish unwinding.
        watchdogProcess = nil
    }

    private func recoverStaleOwnedState() {
        ClamshellOwnershipRecovery.recover(
            store: ownershipStore,
            ownerProcessIsCurrent: { [self] record in
                Self.ownershipIsActivelyLeased(
                    record: record,
                    owningProcessIsLive: ClamshellOwnershipStore.belongsToCurrentProcess(record),
                    currentProcessID: ProcessInfo.processInfo.processIdentifier,
                    activeSessionToken: activeSessionToken,
                    watchdogToken: watchdogLease?.token
                )
            },
            systemSleepIsDisabled: currentSystemStatus,
            authorizationIsInstalled: { self.isAuthorized },
            restoreNormalSleep: { ClamshellWatchdog.runPMSet(enabled: false) }
        )
    }

    static func ownershipIsActivelyLeased(
        record: ClamshellOwnershipRecord,
        owningProcessIsLive: Bool,
        currentProcessID: Int32,
        activeSessionToken: String?,
        watchdogToken: String?
    ) -> Bool {
        guard owningProcessIsLive else { return false }

        // A different live SteamPack process still owns its record. For this
        // process, PID identity alone is insufficient: a missing token/watchdog
        // means the lease was abandoned and recovery must be retried.
        guard record.processID == currentProcessID else { return true }
        return activeSessionToken == record.token && watchdogToken == record.token
    }
}
