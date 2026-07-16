import Foundation

enum ClamshellWatchdog {
    static let argument = "--clamshell-watchdog"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count == 4, arguments[1] == argument else { return false }
        let token = arguments[2]
        let ownershipURL = URL(fileURLWithPath: arguments[3])

        // The app owns the write side of stdin. EOF therefore means every normal and
        // abnormal app exit path (including SIGKILL and a crash) has closed the lease.
        _ = FileHandle.standardInput.readDataToEndOfFile()

        let store = ClamshellOwnershipStore(url: ownershipURL)
        _ = restoreIfOwned(token: token, store: store) {
            runPMSet(enabled: false)
        }
        return true
    }

    @discardableResult
    static func restoreIfOwned(
        token: String,
        store: ClamshellOwnershipStore,
        restore: () -> Bool
    ) -> Bool {
        guard store.matches(token: token), restore() else { return false }
        store.clearIfMatching(token: token)
        return true
    }

    @discardableResult
    static func runPMSet(enabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "disablesleep", enabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
