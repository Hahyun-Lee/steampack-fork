import Foundation

/// Closed-lid sleep prevention backed by the narrowly-scoped sudoers rule.
/// A mandatory watchdog owns a pipe lease and restores normal sleep when the
/// app exits, crashes, or is killed.
final class ClamshellMode {
    private(set) var isOn = false
    private(set) var isExternallyDisabled = false

    var onWatchdogFailure: (() -> Void)?

    private let ownershipStore: ClamshellOwnershipStore
    private let sessionToken = UUID().uuidString
    private var watchdogProcess: Process?
    private var watchdogLease: FileHandle?
    private var watchdogExpectedExit = false

    init(ownershipStore: ClamshellOwnershipStore = .defaultStore()) {
        self.ownershipStore = ownershipStore
        recoverStaleOwnedState()
        refresh()
    }

    var isAuthorized: Bool {
        ClamshellAuthorization.isInstalled()
    }

    func refresh() {
        let systemDisabled = currentSystemStatus()
        let ownedByThisSession = ownershipStore.matches(token: sessionToken)
        isOn = systemDisabled && ownedByThisSession
        isExternallyDisabled = systemDisabled && !ownedByThisSession

        if !systemDisabled && ownedByThisSession {
            ownershipStore.clearIfMatching(token: sessionToken)
            stopWatchdog()
        }
    }

    func currentSystemStatus() -> Bool {
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
            return false
        }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
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
        guard !isOn else { return .success }
        guard !isExternallyDisabled else {
            return .failed("Sleep is already disabled by another app or command.")
        }
        guard isAuthorized else {
            return .failed("Clamshell permission is not installed.")
        }

        let record = ClamshellOwnershipRecord(
            token: sessionToken,
            processID: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date()
        )
        do {
            try ownershipStore.write(record)
        } catch {
            return .failed("Could not create the crash-recovery lease: \(error.localizedDescription)")
        }

        guard startWatchdog() else {
            ownershipStore.clearIfMatching(token: sessionToken)
            return .failed("The crash-recovery watchdog could not start.")
        }

        guard ClamshellWatchdog.runPMSet(enabled: true) else {
            ownershipStore.clearIfMatching(token: sessionToken)
            stopWatchdog()
            return .failed("macOS rejected the sleep setting.")
        }

        isOn = true
        isExternallyDisabled = false
        return .success
    }

    private func disable() -> ToggleResult {
        guard isOn else { return .success }
        guard ClamshellWatchdog.runPMSet(enabled: false) else {
            return .failed("macOS could not restore normal sleep.")
        }

        isOn = false
        isExternallyDisabled = false
        ownershipStore.clearIfMatching(token: sessionToken)
        stopWatchdog()
        return .success
    }

    private func startWatchdog() -> Bool {
        guard watchdogProcess == nil,
              let executableURL = Bundle.main.executableURL else { return false }

        let lease = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            ClamshellWatchdog.argument,
            sessionToken,
            ownershipStore.url.path
        ]
        process.standardInput = lease
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        watchdogExpectedExit = false
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let expected = self.watchdogExpectedExit
                self.watchdogProcess = nil
                self.watchdogLease = nil
                self.watchdogExpectedExit = false
                guard !expected, self.isOn else { return }

                // A Clamshell session without a watchdog is never allowed to continue.
                _ = ClamshellWatchdog.runPMSet(enabled: false)
                self.isOn = false
                self.ownershipStore.clearIfMatching(token: self.sessionToken)
                self.onWatchdogFailure?()
            }
        }

        do {
            try process.run()
            lease.fileHandleForReading.closeFile()
            watchdogProcess = process
            watchdogLease = lease.fileHandleForWriting
            return true
        } catch {
            lease.fileHandleForReading.closeFile()
            lease.fileHandleForWriting.closeFile()
            return false
        }
    }

    private func stopWatchdog() {
        guard watchdogProcess != nil || watchdogLease != nil else { return }
        watchdogExpectedExit = true
        watchdogLease?.closeFile()
        watchdogLease = nil
    }

    private func recoverStaleOwnedState() {
        guard let record = ownershipStore.read(),
              !ClamshellOwnershipStore.isProcessAlive(record.processID) else { return }

        if currentSystemStatus(), isAuthorized {
            guard ClamshellWatchdog.runPMSet(enabled: false) else { return }
        }
        ownershipStore.clearIfMatching(token: record.token)
    }
}
