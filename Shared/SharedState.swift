import Foundation
import Darwin

enum SteamPackControlChannel: String, Codable, Equatable {
    case keepAwake
    case clamshell
}

struct SteamPackControlRequest: Codable, Equatable {
    var keepAwake: Bool
    var clamshell: Bool
    var revision: UInt64
    var updatedAt: Date
    var source: SteamPackControlChannel?
    var rollbackKeepAwake: Bool?
    var rollbackClamshell: Bool?
    var expiresAt: Date?

    init(
        keepAwake: Bool,
        clamshell: Bool,
        revision: UInt64,
        updatedAt: Date,
        source: SteamPackControlChannel? = nil,
        rollbackKeepAwake: Bool? = nil,
        rollbackClamshell: Bool? = nil,
        expiresAt: Date? = nil
    ) {
        self.keepAwake = keepAwake || clamshell
        self.clamshell = clamshell
        self.revision = revision
        self.updatedAt = updatedAt
        self.source = source
        self.rollbackKeepAwake = rollbackKeepAwake.map {
            $0 || (rollbackClamshell ?? false)
        }
        self.rollbackClamshell = rollbackClamshell
        self.expiresAt = expiresAt
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard source != nil, let expiresAt else { return false }
        return now >= expiresAt
    }

    var rollbackMode: SteamPackControlPolicy.DesiredMode {
        SteamPackControlPolicy.desiredMode(
            requestedKeepAwake: rollbackKeepAwake ?? false,
            requestedClamshell: rollbackClamshell ?? false
        )
    }
}

struct SteamPackAppliedState: Codable, Equatable {
    let keepAwake: Bool
    let clamshell: Bool
    let requestRevision: UInt64?
    let requestSource: SteamPackControlChannel?
    let requestSucceeded: Bool?
    let updatedAt: Date

    init(
        keepAwake: Bool,
        clamshell: Bool,
        requestRevision: UInt64? = nil,
        requestSource: SteamPackControlChannel? = nil,
        requestSucceeded: Bool? = nil,
        updatedAt: Date
    ) {
        self.keepAwake = keepAwake
        self.clamshell = clamshell
        self.requestRevision = requestRevision
        self.requestSource = requestSource
        self.requestSucceeded = requestSucceeded
        self.updatedAt = updatedAt
    }
}

enum SteamPackControlWriteResult: Equatable {
    case written(SteamPackControlRequest)
    case conflict(SteamPackControlRequest)
    case failed
}

enum SteamPackAppliedRequestStatus: Equatable {
    case pending
    case applied
    case rejected
    case superseded
}

struct SteamPackControlAcknowledgement: Equatable {
    let requestRevision: UInt64
    let source: SteamPackControlChannel
    let succeeded: Bool

    static func evaluate(
        request: SteamPackControlRequest,
        acceptedIncomingRequest: Bool,
        appliedKeepAwake: Bool,
        appliedClamshell: Bool,
        now: Date = Date()
    ) -> SteamPackControlAcknowledgement? {
        guard let source = request.source else { return nil }
        let normalizedKeepAwake = appliedKeepAwake || appliedClamshell
        let matchesCompleteMode = normalizedKeepAwake == request.keepAwake
            && appliedClamshell == request.clamshell
        return SteamPackControlAcknowledgement(
            requestRevision: request.revision,
            source: source,
            succeeded: acceptedIncomingRequest
                && !request.isExpired(now: now)
                && matchesCompleteMode
        )
    }
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

    static let appliedStateMaxAge: TimeInterval = 6
    static let controlRequestLifetime: TimeInterval = 5
    private static let appliedStateFile = "applied-state.json"
    private static let controlRequestFile = "control-request.json"
    private static let controlRequestLockFile = "control-request.lock"
    private static let controlRevisionFile = "control-revision.state"
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
              now.timeIntervalSince(state.updatedAt) <= appliedStateMaxAge else {
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
        requestKeepAwakeRecord(enabled) != nil
    }

    static func requestKeepAwakeRecord(_ enabled: Bool) -> SteamPackControlRequest? {
        guard let initialApplied = readAppliedState() else { return nil }
        let result = mutateControlRequest { request in
            let now = Date()
            let applied = readAppliedState(now: now) ?? initialApplied
            // Compose with a fresh request that is still genuinely pending so a
            // rapid cross-control tap changes only the field the user touched.
            // Terminal rejection, expiry, or acknowledgement instead rebases on
            // the last verified applied mode and cannot leak a failed target.
            if !shouldComposeWithPendingRequest(
                request,
                appliedState: applied,
                now: now
            ) {
                request.keepAwake = applied.keepAwake
                request.clamshell = applied.clamshell
            }
            request.keepAwake = enabled
            if !enabled {
                // Keep Awake is the umbrella control: turning it off requests that
                // Closed Lid stop as well.
                request.clamshell = false
            }
            request.source = .keepAwake
            request.rollbackKeepAwake = applied.keepAwake
            request.rollbackClamshell = applied.clamshell
            request.expiresAt = now.addingTimeInterval(controlRequestLifetime)
        }
        guard case .written(let request) = result else { return nil }
        post(keepAwakeRequestName)
        return request
    }

    @discardableResult
    static func requestClamshell(_ enabled: Bool) -> Bool {
        requestClamshellRecord(enabled) != nil
    }

    static func requestClamshellRecord(_ enabled: Bool) -> SteamPackControlRequest? {
        guard let initialApplied = readAppliedState() else { return nil }
        let result = mutateControlRequest { request in
            let now = Date()
            let applied = readAppliedState(now: now) ?? initialApplied
            if !shouldComposeWithPendingRequest(
                request,
                appliedState: applied,
                now: now
            ) {
                request.keepAwake = applied.keepAwake
                request.clamshell = applied.clamshell
            }
            request.clamshell = enabled
            if enabled {
                // Closed Lid implies Keep Awake. Both values are committed in one
                // atomic, revisioned record before a notification is posted.
                request.keepAwake = true
            }
            request.source = .clamshell
            request.rollbackKeepAwake = applied.keepAwake
            request.rollbackClamshell = applied.clamshell
            request.expiresAt = now.addingTimeInterval(controlRequestLifetime)
        }
        guard case .written(let request) = result else { return nil }
        post(clamshellRequestName)
        return request
    }

    static func appliedStatus(
        for request: SteamPackControlRequest,
        now: Date = Date()
    ) -> SteamPackAppliedRequestStatus {
        guard let state = readAppliedState(now: now) else { return .pending }
        return appliedStatus(for: request, appliedState: state, now: now)
    }

    private static func shouldComposeWithPendingRequest(
        _ request: SteamPackControlRequest,
        appliedState: SteamPackAppliedState,
        now: Date
    ) -> Bool {
        guard request.source != nil, !request.isExpired(now: now) else {
            return false
        }
        return appliedStatus(
            for: request,
            appliedState: appliedState,
            now: now
        ) == .pending
    }

    private static func appliedStatus(
        for request: SteamPackControlRequest,
        appliedState state: SteamPackAppliedState,
        now: Date
    ) -> SteamPackAppliedRequestStatus {
        guard let appliedRevision = state.requestRevision,
              appliedRevision >= request.revision else {
            return .pending
        }
        if appliedRevision > request.revision {
            // A newer successful Control Center gesture may supersede an older
            // rapid tap without turning it into an error. Local safety, menu,
            // timeout rollback, or a failed newer request must not masquerade as
            // success for the older intent.
            return state.requestSource != nil && state.requestSucceeded == true
                ? .superseded
                : .rejected
        }
        if let source = request.source {
            if state.requestSucceeded == false { return .rejected }
            guard let acknowledgedSource = state.requestSource else {
                // A heartbeat or legacy/local publication with matching Booleans
                // is not a durable acknowledgement of this Control Center action.
                return .pending
            }
            guard acknowledgedSource == source else { return .rejected }
            guard state.requestSucceeded == true else { return .pending }
        } else if state.requestSucceeded == false {
            return .rejected
        }
        if let expiresAt = request.expiresAt,
           state.updatedAt >= expiresAt {
            return .rejected
        }

        // A linked control request is successful only if the complete mode was
        // applied. Checking just the tapped Boolean can falsely report success
        // when the sibling transition failed (for example Closed Lid OFF could
        // stop pmset but fail to start Keep Awake).
        let matches = state.keepAwake == request.keepAwake
            && state.clamshell == request.clamshell
        return matches ? .applied : .rejected
    }

    @discardableResult
    static func cancelTimedOutControlRequest(
        _ timedOutRequest: SteamPackControlRequest
    ) -> SteamPackControlWriteResult {
        guard let source = timedOutRequest.source,
              let rollbackKeepAwake = timedOutRequest.rollbackKeepAwake,
              let rollbackClamshell = timedOutRequest.rollbackClamshell else {
            return .failed
        }
        let result = mutateControlRequest(
            requiredCurrentRevision: timedOutRequest.revision
        ) { request in
            request.keepAwake = rollbackKeepAwake || rollbackClamshell
            request.clamshell = rollbackClamshell
            request.source = nil
            request.rollbackKeepAwake = nil
            request.rollbackClamshell = nil
            request.expiresAt = nil
        }
        if case .written = result {
            post(source == .keepAwake ? keepAwakeRequestName : clamshellRequestName)
        }
        return result
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
            request.source = nil
            request.rollbackKeepAwake = nil
            request.rollbackClamshell = nil
            request.expiresAt = nil
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
            request.source = nil
            request.rollbackKeepAwake = nil
            request.rollbackClamshell = nil
            request.expiresAt = nil
        }
    }

    @discardableResult
    static func publishApplied(
        keepAwake: Bool,
        clamshell: Bool,
        requestRevision: UInt64? = nil,
        requestSource: SteamPackControlChannel? = nil,
        requestSucceeded: Bool? = nil,
        now: Date = Date()
    ) -> Bool {
        let state = SteamPackAppliedState(
            keepAwake: keepAwake || clamshell,
            clamshell: clamshell,
            requestRevision: requestRevision,
            requestSource: requestSource,
            requestSucceeded: requestSucceeded,
            updatedAt: now
        )
        guard writeJSON(state, to: stateFileURL(appliedStateFile)) else {
            // Best-effort immediate fail-closed invalidation. If removal is also
            // denied, the previous record still expires within appliedStateMaxAge.
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
            requestRevision: nil,
            requestSource: nil,
            requestSucceeded: nil,
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
        requiredCurrentRevision: UInt64? = nil,
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

            let requestURL = stateFileURL(controlRequestFile)
            let requestFileExists = FileManager.default.fileExists(atPath: requestURL.path)
            var request: SteamPackControlRequest
            if requestFileExists {
                // Existing-but-invalid is not equivalent to absent. Falling back
                // to revision zero here could make a stale request look newer or
                // make a later applied revision falsely supersede it.
                guard let stored = readControlRequestRecord() else { return .failed }
                request = stored
            } else {
                request = migratedControlRequest()
            }
            if let requiredCurrentRevision,
               request.revision != requiredCurrentRevision {
                return .conflict(request)
            }
            if let maximumCurrentRevision,
               request.revision > maximumCurrentRevision {
                return .conflict(request)
            }
            mutation(&request)

            let revisionURL = stateFileURL(controlRevisionFile)
            let revisionFileExists = FileManager.default.fileExists(atPath: revisionURL.path)
            let storedHighWatermark = readString(controlRevisionFile).flatMap(UInt64.init)
            if revisionFileExists, storedHighWatermark == nil { return .failed }
            let appliedHighWatermark = readAppliedState()?.requestRevision ?? 0
            let revisionFloor = max(
                request.revision,
                max(storedHighWatermark ?? 0, appliedHighWatermark)
            )
            guard revisionFloor < UInt64.max else { return .failed }
            let nextRevision = revisionFloor + 1
            // Reserve the revision first. A failed request write may leave a gap,
            // but it can never cause revision reuse or rollback.
            guard writeString(controlRevisionFile, String(nextRevision)) else {
                return .failed
            }
            request.revision = nextRevision
            request.updatedAt = Date()
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
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
    mutating func extendPendingIntent(throughRevision: UInt64) -> Bool {
        guard var pendingIntent else { return false }
        pendingIntent.throughRevision = max(
            pendingIntent.throughRevision,
            throughRevision
        )
        self.pendingIntent = pendingIntent
        return true
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
    case requestRejected
    case responseTimedOut
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return SteamPackL10n.text("Open SteamPack before using this control.")
        case .requestRejected:
            return SteamPackL10n.text(
                "SteamPack could not apply this control. Check the app menu."
            )
        case .responseTimedOut:
            return SteamPackL10n.text(
                "SteamPack did not confirm this control in time. Try again."
            )
        case .stateUnavailable:
            return SteamPackL10n.text(
                "SteamPack state is temporarily unavailable. Open the app and try again."
            )
        }
    }
}
