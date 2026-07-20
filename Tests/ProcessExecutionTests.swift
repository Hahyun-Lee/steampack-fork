import Foundation
import XCTest
@testable import SteamPack

final class ProcessExecutionTests: XCTestCase {
    func testProcessTimeoutBudgetsFitInsideControlRequestLifetime() {
        let lifetime = SteamPackShared.controlRequestLifetime

        XCTAssertGreaterThan(SteamPackProcessTimeout.statusQuery, 0)
        XCTAssertGreaterThan(SteamPackProcessTimeout.privilegedMutation, 0)
        XCTAssertGreaterThan(SteamPackProcessTimeout.validation, 0)
        XCTAssertLessThan(SteamPackProcessTimeout.statusQuery, lifetime)
        XCTAssertLessThan(SteamPackProcessTimeout.privilegedMutation, lifetime)
        XCTAssertLessThan(SteamPackProcessTimeout.validation, lifetime)
        XCTAssertGreaterThan(
            SteamPackProcessTimeout.privilegedMutation,
            TimeInterval(ClamshellAuthorizationLayout.commandTimeoutSeconds),
            "sudo must get time to terminate and reap pmset before the outer runner stops sudo"
        )
        XCTAssertLessThan(
            (2 * SteamPackProcessTimeout.privilegedMutation)
                + (2 * SteamPackProcessTimeout.statusQuery),
            lifetime,
            "stale-lease recovery, enable, and both status checks must fit one control request"
        )
    }

    func testBoundedProcessRunnerReturnsSuccessfulExitStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")

        let status = try SteamPackProcessTimeout.run(process, timeout: 0.5)

        XCTAssertEqual(status, 0)
        XCTAssertFalse(process.isRunning)
    }

    func testBoundedProcessRunnerTerminatesTimedOutChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let startedAt = Date()

        let status = try SteamPackProcessTimeout.run(process, timeout: 0.05)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertNil(status)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(elapsed, 1)
    }
}
