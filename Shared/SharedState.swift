import Foundation
import Darwin

struct SteamPackControlRequest: Codable, Equatable {
    var keepAwake: Bool
    var clamshell: Bool
    var revision: UInt64
    var updatedAt: Date
}

struct SteamPackAppliedState: Codable, Equatable {
    let keepAwake: Bool
    let clamshell: Bool
    let updatedAt: Date
}

enum SteamPackControlWriteResult: Equatable {
    case written(SteamPackControlRequest)
    case conflict(SteamPackControlRequest)
    case failed
}

/// Small file-based bridge between the non-sandboxed menu bar app and the
/// sandboxed Control Widget extension. Requested and applied values are kept
/// separate so Control Center never presents an unconfirmed state as real.
enum SteamPackShared {
    static let controlBundleID = "com.steampack.app.control"
    static let keepAwakeKind = "com.steampack.app.keepawake"
    static let clamshellKind = "com.steampack.app.clamshell"

    static let keepAwakeRequestName = "com.steampack.keepAwakeRequested" as CFString
    static let clamshellRequestName = "com.steampack.clamshellRequested" as CFString

    private static let heartbeatMaxAge: TimeInterval = 6
    private static let appliedStateFile = "applied-state.json"
    private static let controlRequestFile = "control-request.json"
    private static let controlRequestLockFile = "control-request.lock"
    private static let controlProcessLock = NSRecursiveLock()

    static func readAppliedKeepAwake() -> Bool {
        readAppliedState()?.keepAwake ?? false
    }

    static func readAppliedClamshell() -> Bool {
        readAppliedState()?.clamshell ?? false
    }

    static func readAppliedState(now: Date = Date()) -> SteamPackAppliedState? {
        guard let state = storedOrMigratedAppliedState(),
              state.updatedAt <= now,
              now.timeIntervalSince(state.updatedAt) <= heartbeatMaxAge else {
            return nil
        }
        return state
    }

    static func readRequestedKeepAwake() -> Bool {
        readControlRequest().keepAwake
    }

    static func readRequestedClamshell() -> Bool {
        readControlRequest().clamshell
    }

    static func readControlRequest() -> SteamPackControlRequest {
        readControlRequestRecord() ?? migratedControlRequest()
    }

    @discardableResult
    static func requestKeepAwake(_ enabled: Bool) -> Bool {
        guard isAppAlive() else { return false }
        let result = mutateControlRequest { request in
            request.keepAwake = enabled
            if !enabled {
                // Keep Awake is the umbrella control: turning it off requests that
                // Closed Lid stop as well.
                request.clamshell = false
            }
        }
        guard case .written = result else { return false }
        post(keepAwakeRequestName)
        return true
    }

    @discardableResult
    static func requestClamshell(_ enabled: Bool) -> Bool {
        guard isAppAlive() else { return false }
        let result = mutateControlRequest { request in
            request.clamshell = enabled
            if enabled {
                // Closed Lid implies Keep Awake. Both values are committed in one
                // atomic, revisioned record before a notification is posted.
                request.keepAwake = true
            }
        }
        guard case .written = result else { return false }
        post(clamshellRequestName)
        return true
    }

    @discardableResult
    static func resetControlRequest(keepAwake: Bool, clamshell: Bool) -> Bool {
        resetControlRequestRecord(keepAwake: keepAwake, clamshell: clamshell) != nil
    }

    static func resetControlRequestRecord(
        keepAwake: Bool,
        clamshell: Bool
    ) -> SteamPackControlRequest? {
        let result = mutateControlRequest { request in
            request.keepAwake = keepAwake || clamshell
            request.clamshell = clamshell
        }
        guard case .written(let request) = result else { return nil }
        return request
    }

    static func compareAndResetControlRequest(
        keepAwake: Bool,
        clamshell: Bool,
        ifCurrentRevisionAtMost maximumRevision: UInt64
    ) -> SteamPackControlWriteResult {
        mutateControlRequest(maximumCurrentRevision: maximumRevision) { request in
            request.keepAwake = keepAwake || clamshell
            request.clamshell = clamshell
        }
    }

    @discardableResult
    static func publishApplied(
        keepAwake: Bool,
        clamshell: Bool,
        now: Date = Date()
    ) -> Bool {
        let state = SteamPackAppliedState(
            keepAwake: keepAwake || clamshell,
            clamshell: clamshell,
            updatedAt: now
        )
        guard writeJSON(state, to: stateFileURL(appliedStateFile)) else {
            // Best-effort immediate fail-closed invalidation. If removal is also
            // denied, the previous record still expires within heartbeatMaxAge.
            try? FileManager.default.removeItem(at: stateFileURL(appliedStateFile))
            return false
        }
        // The atomic record timestamp is the liveness signal. Retire the legacy
        // marker only after the replacement record is durable.
        try? FileManager.default.removeItem(at: stateFileURL("app-heartbeat.state"))
        return true
    }

    @discardableResult
    static func publishHeartbeat(now: Date = Date()) -> Bool {
        writeString("app-heartbeat.state", String(now.timeIntervalSince1970))
    }

    static func clearHeartbeat() {
        try? FileManager.default.removeItem(at: stateFileURL(appliedStateFile))
        try? FileManager.default.removeItem(at: stateFileURL("app-heartbeat.state"))
    }

    static func isAppAlive(now: Date = Date()) -> Bool {
        readAppliedState(now: now) != nil
    }

    static func stateFileURL(_ name: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["STEAMPACK_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent(name)
        }

        let home = NSHomeDirectory()
        let directory: URL
        if home.contains("/Containers/\(controlBundleID)/") {
            directory = URL(fileURLWithPath: home)
        } else {
            directory = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Containers/\(controlBundleID)/Data")
        }
        return directory.appendingPathComponent(name)
    }

    private static func readBool(_ name: String) -> Bool {
        readString(name) == "1"
    }

    private static func storedOrMigratedAppliedState() -> SteamPackAppliedState? {
        let url = stateFileURL(appliedStateFile)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SteamPackAppliedState.self, from: data)
        }

        // Compatibility for a running pre-record build during an in-place update.
        guard let rawHeartbeat = readString("app-heartbeat.state"),
              let heartbeat = TimeInterval(rawHeartbeat) else { return nil }
        let legacyClamshell = readBool("applied-clamshell.state")
        return SteamPackAppliedState(
            keepAwake: readBool("applied-keep-awake.state") || legacyClamshell,
            clamshell: legacyClamshell,
            updatedAt: Date(timeIntervalSince1970: heartbeat)
        )
    }

    private static func readControlRequestRecord() -> SteamPackControlRequest? {
        guard let data = try? Data(contentsOf: stateFileURL(controlRequestFile)) else {
            return nil
        }
        return try? JSONDecoder().decode(SteamPackControlRequest.self, from: data)
    }

    private static func migratedControlRequest() -> SteamPackControlRequest {
        SteamPackControlRequest(
            keepAwake: readBool("requested-keep-awake.state"),
            clamshell: readBool("requested-clamshell.state"),
            revision: 0,
            updatedAt: .distantPast
        )
    }

    private static func mutateControlRequest(
        maximumCurrentRevision: UInt64? = nil,
        _ mutation: (inout SteamPackControlRequest) -> Void
    ) -> SteamPackControlWriteResult {
        // `flock` is the cross-process gate; this lock also serializes callers in
        // the app/extension process before they open independent file handles.
        controlProcessLock.lock()
        defer { controlProcessLock.unlock() }

        let lockURL = stateFileURL(controlRequestLockFile)
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: lockURL.path) {
                _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
                guard FileManager.default.fileExists(atPath: lockURL.path) else {
                    return .failed
                }
            }
            guard let lock = FileHandle(forUpdatingAtPath: lockURL.path) else { return .failed }
            defer { try? lock.close() }
            guard flock(lock.fileDescriptor, LOCK_EX) == 0 else { return .failed }
            defer { _ = flock(lock.fileDescriptor, LOCK_UN) }

            var request = readControlRequestRecord() ?? migratedControlRequest()
            if let maximumCurrentRevision,
               request.revision > maximumCurrentRevision {
                return .conflict(request)
            }
            mutation(&request)
            guard request.revision < UInt64.max else { return .failed }
            request.revision += 1
            request.updatedAt = Date()
            let data = try JSONEncoder().encode(request)
            try data.write(to: stateFileURL(controlRequestFile), options: .atomic)
            return .written(request)
        } catch {
            return .failed
        }
    }

    private static func readString(_ name: String) -> String? {
        guard let value = try? String(contentsOf: stateFileURL(name), encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func writeBool(_ name: String, _ enabled: Bool) -> Bool {
        writeString(name, enabled ? "1" : "0")
    }

    @discardableResult
    private static func writeString(_ name: String, _ value: String) -> Bool {
        let url = stateFileURL(name)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try value.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }
}

enum SteamPackControlPolicy {
    enum DesiredMode: Equatable {
        case normalSleep
        case keepAwake
        case closedLid
    }

    static func desiredMode(
        requestedKeepAwake: Bool,
        requestedClamshell: Bool
    ) -> DesiredMode {
        guard requestedKeepAwake else { return .normalSleep }
        return requestedClamshell ? .closedLid : .keepAwake
    }
}

struct SteamPackLocalIntentBarrier {
    struct PendingIntent: Equatable {
        let mode: SteamPackControlPolicy.DesiredMode
        var throughRevision: UInt64
    }

    struct Resolution: Equatable {
        let mode: SteamPackControlPolicy.DesiredMode
        let acceptedIncomingRequest: Bool
    }

    private(set) var pendingIntent: PendingIntent?

    mutating func begin(
        _ mode: SteamPackControlPolicy.DesiredMode,
        throughRevision: UInt64
    ) {
        pendingIntent = PendingIntent(mode: mode, throughRevision: throughRevision)
    }

    @discardableResult
    mutating func markPersisted(_ request: SteamPackControlRequest) -> Bool {
        guard var pendingIntent,
              Self.mode(for: request) == pendingIntent.mode else { return false }
        pendingIntent.throughRevision = max(
            pendingIntent.throughRevision,
            request.revision
        )
        self.pendingIntent = pendingIntent
        return true
    }

    mutating func resolve(_ request: SteamPackControlRequest) -> Resolution {
        guard let pendingIntent else {
            return Resolution(
                mode: Self.mode(for: request),
                acceptedIncomingRequest: true
            )
        }

        if request.revision > pendingIntent.throughRevision {
            self.pendingIntent = nil
            return Resolution(
                mode: Self.mode(for: request),
                acceptedIncomingRequest: true
            )
        }

        return Resolution(
            mode: pendingIntent.mode,
            acceptedIncomingRequest: false
        )
    }

    mutating func clear() {
        pendingIntent = nil
    }

    private static func mode(
        for request: SteamPackControlRequest
    ) -> SteamPackControlPolicy.DesiredMode {
        SteamPackControlPolicy.desiredMode(
            requestedKeepAwake: request.keepAwake,
            requestedClamshell: request.clamshell
        )
    }
}

enum SteamPackStopAttempt: Equatable {
    case success
    case failed(String)
}

struct SteamPackStopReport: Equatable {
    let failures: [String]

    init(attempts: [SteamPackStopAttempt]) {
        failures = attempts.compactMap { attempt in
            guard case .failed(let message) = attempt else { return nil }
            return message
        }
    }
}

enum SteamPackControlError: LocalizedError {
    case appNotRunning

    var errorDescription: String? {
        SteamPackL10n.text("Open SteamPack before using this control.")
    }
}
