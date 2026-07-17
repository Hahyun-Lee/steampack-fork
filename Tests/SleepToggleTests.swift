import XCTest
@testable import SteamPack

final class SleepToggleTests: XCTestCase {
    private final class ProcessSentinel {}

    func testOldTerminationHandlerCannotClearRapidlyReenabledSession() {
        let oldProcess = ProcessSentinel()
        let newProcess = ProcessSentinel()
        let oldSession = SleepToggleSessionIdentity(
            token: "old-enable",
            processID: 42,
            processObjectID: ObjectIdentifier(oldProcess)
        )
        let newSession = SleepToggleSessionIdentity(
            token: "new-enable",
            processID: 42,
            processObjectID: ObjectIdentifier(newProcess)
        )
        var state = SleepToggleSessionState()
        var stateChangeCount = 0

        state.activate(oldSession)
        XCTAssertTrue(state.clearIfMatching(oldSession))
        state.activate(newSession)

        if state.consumeTermination(oldSession) {
            stateChangeCount += 1
        }
        XCTAssertEqual(stateChangeCount, 0)
        XCTAssertEqual(state.activeSession, newSession)

        if state.consumeTermination(newSession) {
            stateChangeCount += 1
        }
        if state.consumeTermination(newSession) {
            stateChangeCount += 1
        }
        XCTAssertEqual(stateChangeCount, 1)
        XCTAssertNil(state.activeSession)
    }

    func testPIDAndTokenWithoutTheSameProcessObjectDoNotMatch() {
        let retainedProcess = ProcessSentinel()
        let reusedPIDProcess = ProcessSentinel()
        let active = SleepToggleSessionIdentity(
            token: "enable-token",
            processID: 73,
            processObjectID: ObjectIdentifier(retainedProcess)
        )
        let reusedPID = SleepToggleSessionIdentity(
            token: "enable-token",
            processID: 73,
            processObjectID: ObjectIdentifier(reusedPIDProcess)
        )
        var state = SleepToggleSessionState()
        state.activate(active)

        XCTAssertFalse(state.matches(reusedPID))
        XCTAssertFalse(state.clearIfMatching(reusedPID))
        XCTAssertEqual(state.activeSession, active)
    }
}
