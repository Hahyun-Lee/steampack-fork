import Foundation

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

    static func readAppliedKeepAwake() -> Bool {
        isAppAlive() && readBool("applied-keep-awake.state")
    }

    static func readAppliedClamshell() -> Bool {
        isAppAlive() && readBool("applied-clamshell.state")
    }

    static func readRequestedKeepAwake() -> Bool {
        readBool("requested-keep-awake.state")
    }

    static func readRequestedClamshell() -> Bool {
        readBool("requested-clamshell.state")
    }

    @discardableResult
    static func requestKeepAwake(_ enabled: Bool) -> Bool {
        guard isAppAlive(), writeBool("requested-keep-awake.state", enabled) else { return false }
        post(keepAwakeRequestName)
        return true
    }

    @discardableResult
    static func requestClamshell(_ enabled: Bool) -> Bool {
        guard isAppAlive(), writeBool("requested-clamshell.state", enabled) else { return false }
        post(clamshellRequestName)
        return true
    }

    static func publishApplied(keepAwake: Bool, clamshell: Bool) {
        _ = writeBool("applied-keep-awake.state", keepAwake)
        _ = writeBool("applied-clamshell.state", clamshell)
        _ = writeBool("requested-keep-awake.state", keepAwake)
        _ = writeBool("requested-clamshell.state", clamshell)
        publishHeartbeat()
    }

    static func publishHeartbeat(now: Date = Date()) {
        _ = writeString("app-heartbeat.state", String(now.timeIntervalSince1970))
    }

    static func clearHeartbeat() {
        try? FileManager.default.removeItem(at: stateFileURL("app-heartbeat.state"))
    }

    static func isAppAlive(now: Date = Date()) -> Bool {
        guard let raw = readString("app-heartbeat.state"),
              let timestamp = TimeInterval(raw),
              timestamp <= now.timeIntervalSince1970 else { return false }
        return now.timeIntervalSince1970 - timestamp <= heartbeatMaxAge
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

enum SteamPackControlError: LocalizedError {
    case appNotRunning

    var errorDescription: String? {
        "Open SteamPack before using this control."
    }
}
