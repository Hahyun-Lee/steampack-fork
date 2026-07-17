import Foundation
import Darwin

struct ClamshellOwnershipRecord: Codable, Equatable {
    let token: String
    let processID: Int32
    let startedAt: Date
    let processStartedAt: Date?

    init(
        token: String,
        processID: Int32,
        startedAt: Date,
        processStartedAt: Date? = nil
    ) {
        self.token = token
        self.processID = processID
        self.startedAt = startedAt
        self.processStartedAt = processStartedAt
    }
}

enum ClamshellSessionLease {
    static func makeRecord(
        token: () -> String = { UUID().uuidString },
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        startedAt: Date = Date(),
        processStartedAt: Date? = nil
    ) -> ClamshellOwnershipRecord {
        ClamshellOwnershipRecord(
            token: token(),
            processID: processID,
            startedAt: startedAt,
            processStartedAt: processStartedAt
                ?? ClamshellOwnershipStore.processStartDate(processID)
        )
    }
}

struct ClamshellOwnershipStore {
    let url: URL

    private static let processLockRegistryGuard = NSLock()
    private static var processLocks: [String: NSRecursiveLock] = [:]

    enum ClaimResult: Equatable {
        case acquired
        case ownedByActiveSession
        case systemStatusUnknown
        case externallyDisabled
        case recoveryAuthorizationRequired
        case recoveryFailed
    }

    enum Resolution {
        case keep
        case clear
    }

    private enum StoreError: Error {
        case lockUnavailable
    }

    static func defaultStore() -> ClamshellOwnershipStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return ClamshellOwnershipStore(
            url: base
                .appendingPathComponent("SteamPack", isDirectory: true)
                .appendingPathComponent("clamshell-owner.json")
        )
    }

    func read() -> ClamshellOwnershipRecord? {
        try? withLock(mode: LOCK_SH) { readUnlocked() }
    }

    func claim(
        _ record: ClamshellOwnershipRecord,
        existingOwnerIsActive: (ClamshellOwnershipRecord) -> Bool,
        systemSleepIsDisabled: () -> Bool?,
        authorizationIsInstalled: () -> Bool,
        restoreNormalSleep: () -> Bool
    ) throws -> ClaimResult {
        try withLock(mode: LOCK_EX) {
            if let existing = try readUnlockedStrict() {
                // A live lease always wins, even during the short interval after it
                // is written but before its owner applies `pmset disablesleep 1`.
                guard !existingOwnerIsActive(existing) else {
                    return .ownedByActiveSession
                }

                guard let disabled = systemSleepIsDisabled() else {
                    return .systemStatusUnknown
                }
                if disabled {
                    guard authorizationIsInstalled() else {
                        return .recoveryAuthorizationRequired
                    }
                    guard restoreNormalSleep() else { return .recoveryFailed }
                }
            } else {
                // No SteamPack provenance exists. Re-check the global setting
                // inside this same lock and never claim another tool's state.
                guard let disabled = systemSleepIsDisabled() else {
                    return .systemStatusUnknown
                }
                guard !disabled else { return .externallyDisabled }
            }

            try writeUnlocked(record)
            return .acquired
        }
    }

    func matches(token: String) -> Bool {
        read()?.token == token
    }

    func clearIfMatching(token: String) {
        _ = resolveIfMatching(token: token) { _ in .clear }
    }

    @discardableResult
    func resolveIfMatching(
        token: String,
        _ resolution: (ClamshellOwnershipRecord) -> Resolution
    ) -> Bool {
        (try? withLock(mode: LOCK_EX) {
            guard let record = readUnlocked(), record.token == token else { return false }
            guard case .clear = resolution(record) else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        }) ?? false
    }

    private func readUnlocked() -> ClamshellOwnershipRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClamshellOwnershipRecord.self, from: data)
    }

    private func readUnlockedStrict() throws -> ClamshellOwnershipRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClamshellOwnershipRecord.self, from: data)
    }

    private func writeUnlocked(_ record: ClamshellOwnershipRecord) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private func withLock<T>(mode: Int32, _ operation: () throws -> T) throws -> T {
        // `flock` protects separate SteamPack processes. Darwin may treat locks
        // opened by the same process as one owner, so pair it with a path-scoped
        // in-process lock for concurrent watchdog/app/test threads.
        let processLock = Self.processLock(for: url)
        processLock.lock()
        defer { processLock.unlock() }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = url.appendingPathExtension("lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
            guard FileManager.default.fileExists(atPath: lockURL.path) else {
                throw StoreError.lockUnavailable
            }
        }
        guard let lock = FileHandle(forUpdatingAtPath: lockURL.path) else {
            throw StoreError.lockUnavailable
        }
        defer { try? lock.close() }
        guard flock(lock.fileDescriptor, mode) == 0 else {
            throw StoreError.lockUnavailable
        }
        defer { _ = flock(lock.fileDescriptor, LOCK_UN) }
        return try operation()
    }

    private static func processLock(for url: URL) -> NSRecursiveLock {
        let key = url.standardizedFileURL.path
        processLockRegistryGuard.lock()
        defer { processLockRegistryGuard.unlock() }
        if let existing = processLocks[key] { return existing }
        let lock = NSRecursiveLock()
        processLocks[key] = lock
        return lock
    }

    static func isProcessAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    static func processStartDate(_ processID: Int32) -> Date? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard result == expectedSize else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    static func belongsToCurrentProcess(_ record: ClamshellOwnershipRecord) -> Bool {
        belongsToCurrentProcess(
            record,
            observedProcessStart: processStartDate(record.processID)
        )
    }

    static func belongsToCurrentProcess(
        _ record: ClamshellOwnershipRecord,
        observedProcessStart: Date?
    ) -> Bool {
        guard isProcessAlive(record.processID) else { return false }

        // If process metadata is temporarily unavailable, preserve the lease rather
        // than risk restoring a mode that a live process still owns.
        guard let observedProcessStart else { return true }

        if let recordedProcessStart = record.processStartedAt {
            return abs(observedProcessStart.timeIntervalSince(recordedProcessStart)) < 0.001
        }

        // Backward compatibility for records written before processStartedAt was
        // added: a reused PID necessarily started after the old lease was created.
        return observedProcessStart <= record.startedAt
    }
}

enum ClamshellOwnershipRecovery {
    static func recover(
        store: ClamshellOwnershipStore,
        ownerProcessIsCurrent: (ClamshellOwnershipRecord) -> Bool,
        systemSleepIsDisabled: () -> Bool?,
        authorizationIsInstalled: () -> Bool,
        restoreNormalSleep: () -> Bool
    ) {
        guard let candidate = store.read() else { return }
        _ = store.resolveIfMatching(token: candidate.token) { record in
            guard !ownerProcessIsCurrent(record) else { return .keep }

            // Unknown is not equivalent to normal sleep. Preserve provenance when
            // pmset cannot launch, exits nonzero, or returns unparseable output.
            guard let disabled = systemSleepIsDisabled() else { return .keep }
            guard disabled else { return .clear }

            // Keep proof of ownership while recovery is blocked so reinstalling
            // permission can retry safely in this same app session.
            guard authorizationIsInstalled(), restoreNormalSleep() else { return .keep }
            return .clear
        }
    }
}
