import XCTest
@testable import SteamPack

final class AppStatePolicyTests: XCTestCase {
    func testFullRefreshIsPeriodicAndBounded() {
        XCTAssertGreaterThanOrEqual(
            SteamPackRuntimeRefreshPolicy.fullStateInterval,
            SteamPackRuntimeRefreshPolicy.heartbeatInterval
        )
        XCTAssertLessThanOrEqual(
            SteamPackRuntimeRefreshPolicy.fullStateInterval,
            15
        )
    }

    func testEveryRuntimeModeChangeIsPersisted() {
        XCTAssertTrue(SteamPackRuntimeRefreshPolicy.shouldPersistRuntimeChange(
            from: .closedLid,
            to: .keepAwake
        ))
        XCTAssertTrue(SteamPackRuntimeRefreshPolicy.shouldPersistRuntimeChange(
            from: .keepAwake,
            to: .normalSleep
        ))
        XCTAssertFalse(SteamPackRuntimeRefreshPolicy.shouldPersistRuntimeChange(
            from: .keepAwake,
            to: .keepAwake
        ))
    }

    func testAutoOffIsCancelledOnlyWhenNoRuntimeModeRemains() {
        XCTAssertTrue(SteamPackRuntimeRefreshPolicy.shouldCancelAutoOff(
            after: .normalSleep
        ))
        XCTAssertFalse(SteamPackRuntimeRefreshPolicy.shouldCancelAutoOff(
            after: .keepAwake
        ))
        XCTAssertFalse(SteamPackRuntimeRefreshPolicy.shouldCancelAutoOff(
            after: .closedLid
        ))
    }
}
