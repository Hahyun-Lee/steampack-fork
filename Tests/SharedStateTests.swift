import XCTest
@testable import SteamPack

final class SharedStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steampack-shared-tests-\(UUID().uuidString)")
        setenv("STEAMPACK_STATE_DIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("STEAMPACK_STATE_DIR")
        try? FileManager.default.removeItem(at: directory)
    }

    func testControlReadsOnlyAppliedStateWhileAppIsAlive() {
        let now = Date()
        SteamPackShared.publishHeartbeat(now: now)
        SteamPackShared.publishApplied(keepAwake: true, clamshell: false)

        XCTAssertTrue(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
    }

    func testStaleHeartbeatForcesControlsOff() {
        let now = Date()
        SteamPackShared.publishApplied(keepAwake: true, clamshell: true)
        SteamPackShared.publishHeartbeat(now: now.addingTimeInterval(-10))

        XCTAssertFalse(SteamPackShared.isAppAlive(now: now))
        XCTAssertFalse(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
    }

    func testRequestIsRejectedWhenAppIsNotAlive() {
        SteamPackShared.clearHeartbeat()
        XCTAssertFalse(SteamPackShared.requestClamshell(true))
        XCTAssertFalse(SteamPackShared.requestKeepAwake(true))
    }
}
