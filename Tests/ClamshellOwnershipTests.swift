import XCTest
@testable import SteamPack

final class ClamshellOwnershipTests: XCTestCase {
    private var directory: URL!
    private var store: ClamshellOwnershipStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steampack-ownership-tests-\(UUID().uuidString)")
        store = ClamshellOwnershipStore(url: directory.appendingPathComponent("owner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOwnershipIsTokenScoped() throws {
        let record = ClamshellOwnershipRecord(token: "current", processID: getpid(), startedAt: Date())
        try store.write(record)

        XCTAssertTrue(store.matches(token: "current"))
        XCTAssertFalse(store.matches(token: "older-watchdog"))

        store.clearIfMatching(token: "older-watchdog")
        XCTAssertNotNil(store.read())

        store.clearIfMatching(token: "current")
        XCTAssertNil(store.read())
    }

    func testCurrentProcessIsAlive() {
        XCTAssertTrue(ClamshellOwnershipStore.isProcessAlive(getpid()))
    }

    func testWatchdogRestoresOnlyItsOwnLease() throws {
        let record = ClamshellOwnershipRecord(token: "current", processID: getpid(), startedAt: Date())
        try store.write(record)
        var restoreCount = 0

        XCTAssertFalse(ClamshellWatchdog.restoreIfOwned(token: "old", store: store) {
            restoreCount += 1
            return true
        })
        XCTAssertEqual(restoreCount, 0)
        XCTAssertNotNil(store.read())

        XCTAssertTrue(ClamshellWatchdog.restoreIfOwned(token: "current", store: store) {
            restoreCount += 1
            return true
        })
        XCTAssertEqual(restoreCount, 1)
        XCTAssertNil(store.read())
    }

    func testFailedRestoreKeepsLeaseForRetry() throws {
        let record = ClamshellOwnershipRecord(token: "current", processID: getpid(), startedAt: Date())
        try store.write(record)

        XCTAssertFalse(ClamshellWatchdog.restoreIfOwned(token: "current", store: store) { false })
        XCTAssertNotNil(store.read())
    }
}
