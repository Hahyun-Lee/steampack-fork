import Foundation
import Dispatch
import Darwin

enum SteamPackProcessTimeout {
    static let statusQuery: TimeInterval = 0.5
    static let privilegedMutation: TimeInterval = 1
    static let validation: TimeInterval = 3
    private static let terminationGrace: TimeInterval = 0.2

    /// Starts a configured child process and waits for a bounded amount of time.
    /// A timeout terminates the exact child and reports no exit status, so callers
    /// fail closed instead of blocking the menu/UI or a Control Center intent.
    static func run(
        _ process: Process,
        timeout: TimeInterval
    ) throws -> Int32? {
        let completed = DispatchSemaphore(value: 0)
        let previousHandler = process.terminationHandler
        process.terminationHandler = { terminatedProcess in
            completed.signal()
            previousHandler?(terminatedProcess)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = previousHandler
            throw error
        }

        if completed.wait(timeout: .now() + timeout) == .success {
            return process.terminationStatus
        }

        if process.isRunning {
            process.terminate()
        }
        if completed.wait(timeout: .now() + terminationGrace) == .timedOut {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            _ = completed.wait(timeout: .now() + terminationGrace)
        }
        return nil
    }
}
