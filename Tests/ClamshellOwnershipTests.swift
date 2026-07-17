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

    @discardableResult
    private func seed(
        _ record: ClamshellOwnershipRecord,
        in targetStore: ClamshellOwnershipStore? = nil
    ) throws -> ClamshellOwnershipStore.ClaimResult {
        let result = try (targetStore ?? store).claim(
            record,
            existingOwnerIsActive: { _ in false },
            systemSleepIsDisabled: { false },
            authorizationIsInstalled: { true },
            restoreNormalSleep: { true }
        )
        XCTAssertEqual(result, .acquired)
        return result
    }

    func testOwnershipIsTokenScoped() throws {
        let record = ClamshellOwnershipRecord(token: "current", processID: getpid(), startedAt: Date())
        try seed(record)

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

    func testRapidReenableUsesNewTokenAndOldWatchdogCannotRestore() throws {
        var tokens = ["first-enable", "second-enable"]
        let processStart = try XCTUnwrap(ClamshellOwnershipStore.processStartDate(getpid()))
        let first = ClamshellSessionLease.makeRecord(
            token: { tokens.removeFirst() },
            processID: getpid(),
            processStartedAt: processStart
        )
        try seed(first)

        let second = ClamshellSessionLease.makeRecord(
            token: { tokens.removeFirst() },
            processID: getpid(),
            processStartedAt: processStart
        )
        store.clearIfMatching(token: first.token)
        try seed(second)

        XCTAssertNotEqual(first.token, second.token)
        var restoreCount = 0
        XCTAssertFalse(ClamshellWatchdog.restoreIfOwned(token: first.token, store: store) {
            restoreCount += 1
            return true
        })
        XCTAssertEqual(restoreCount, 0)
        XCTAssertEqual(store.read(), second)
    }

    func testSecondStoreCannotOverwriteALiveLease() throws {
        let secondStore = ClamshellOwnershipStore(url: store.url)
        let processStart = try XCTUnwrap(ClamshellOwnershipStore.processStartDate(getpid()))
        let first = ClamshellSessionLease.makeRecord(
            token: { "first-instance" },
            processID: getpid(),
            processStartedAt: processStart
        )
        let second = ClamshellSessionLease.makeRecord(
            token: { "second-instance" },
            processID: getpid(),
            processStartedAt: processStart
        )
        try seed(first)

        let result = try secondStore.claim(
            second,
            existingOwnerIsActive: ClamshellOwnershipStore.belongsToCurrentProcess,
            systemSleepIsDisabled: { false },
            authorizationIsInstalled: { true },
            restoreNormalSleep: { true }
        )

        XCTAssertEqual(result, .ownedByActiveSession)
        XCTAssertEqual(store.read(), first)
    }

    func testConcurrentStoresHaveExactlyOneClaimWinner() throws {
        let processStart = try XCTUnwrap(ClamshellOwnershipStore.processStartDate(getpid()))
        let stores = [
            ClamshellOwnershipStore(url: store.url),
            ClamshellOwnershipStore(url: store.url)
        ]
        let records = [
            ClamshellSessionLease.makeRecord(
                token: { "concurrent-a" },
                processID: getpid(),
                processStartedAt: processStart
            ),
            ClamshellSessionLease.makeRecord(
                token: { "concurrent-b" },
                processID: getpid(),
                processStartedAt: processStart
            )
        ]
        let resultLock = NSLock()
        var results: [ClamshellOwnershipStore.ClaimResult] = []
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            do {
                let result = try stores[index].claim(
                    records[index],
                    existingOwnerIsActive: ClamshellOwnershipStore.belongsToCurrentProcess,
                    systemSleepIsDisabled: { false },
                    authorizationIsInstalled: { true },
                    restoreNormalSleep: { true }
                )
                resultLock.lock()
                results.append(result)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(error)
                resultLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(results.filter { $0 == .acquired }.count, 1)
        XCTAssertEqual(results.filter { $0 == .ownedByActiveSession }.count, 1)
        XCTAssertTrue(records.contains(try XCTUnwrap(store.read())))
    }

    func testClaimAtomicallyRecoversAnAbandonedLeaseBeforeReplacement() throws {
        let abandoned = ClamshellOwnershipRecord(
            token: "abandoned",
            processID: Int32.max,
            startedAt: Date()
        )
        try seed(abandoned)
        let replacement = ClamshellSessionLease.makeRecord(token: { "replacement" })
        var restoreCount = 0

        let result = try store.claim(
            replacement,
            existingOwnerIsActive: { _ in false },
            systemSleepIsDisabled: { true },
            authorizationIsInstalled: { true },
            restoreNormalSleep: {
                restoreCount += 1
                return true
            }
        )

        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(store.read(), replacement)
    }

    func testClaimRetainsAbandonedLeaseWhenRecoveryIsNotAuthorized() throws {
        let abandoned = ClamshellOwnershipRecord(
            token: "blocked-recovery",
            processID: Int32.max,
            startedAt: Date()
        )
        try seed(abandoned)
        let replacement = ClamshellSessionLease.makeRecord(token: { "must-not-replace" })
        var restoreCount = 0

        let result = try store.claim(
            replacement,
            existingOwnerIsActive: { _ in false },
            systemSleepIsDisabled: { true },
            authorizationIsInstalled: { false },
            restoreNormalSleep: {
                restoreCount += 1
                return true
            }
        )

        XCTAssertEqual(result, .recoveryAuthorizationRequired)
        XCTAssertEqual(restoreCount, 0)
        XCTAssertEqual(store.read(), abandoned)
    }

    func testNewLeaseWaitsForOldWatchdogRestoreTransaction() throws {
        let old = ClamshellOwnershipRecord(
            token: "old",
            processID: getpid(),
            startedAt: Date()
        )
        let new = ClamshellOwnershipRecord(
            token: "new",
            processID: getpid(),
            startedAt: Date()
        )
        try seed(old)

        let restoreEntered = DispatchSemaphore(value: 0)
        let allowRestore = DispatchSemaphore(value: 0)
        let writerStarted = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        var restoreResult = false
        var writeError: Error?

        group.enter()
        DispatchQueue.global().async {
            restoreResult = ClamshellWatchdog.restoreIfOwned(token: old.token, store: self.store) {
                restoreEntered.signal()
                allowRestore.wait()
                return true
            }
            group.leave()
        }
        XCTAssertEqual(restoreEntered.wait(timeout: .now() + 2), .success)

        group.enter()
        DispatchQueue.global().async {
            writerStarted.signal()
            do {
                let result = try self.store.claim(
                    new,
                    existingOwnerIsActive: { _ in false },
                    systemSleepIsDisabled: { false },
                    authorizationIsInstalled: { true },
                    restoreNormalSleep: { true }
                )
                if result != .acquired {
                    writeError = NSError(
                        domain: "ClamshellOwnershipTests",
                        code: 1
                    )
                }
            } catch {
                writeError = error
            }
            group.leave()
        }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 2), .success)
        allowRestore.signal()

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(restoreResult)
        XCTAssertNil(writeError)
        XCTAssertEqual(store.read(), new)
    }

    func testPIDReuseDoesNotCountAsTheOwningProcess() throws {
        let actualStart = try XCTUnwrap(ClamshellOwnershipStore.processStartDate(getpid()))
        let record = ClamshellOwnershipRecord(
            token: "stale",
            processID: getpid(),
            startedAt: actualStart.addingTimeInterval(-30),
            processStartedAt: actualStart.addingTimeInterval(-60)
        )

        XCTAssertFalse(ClamshellOwnershipStore.belongsToCurrentProcess(
            record,
            observedProcessStart: actualStart
        ))
    }

    func testUnauthorizedRecoveryRetainsLeaseAndRetriesAfterAuthorization() throws {
        let record = ClamshellOwnershipRecord(
            token: "recoverable",
            processID: Int32.max,
            startedAt: Date()
        )
        try seed(record)
        var restoreCount = 0

        ClamshellOwnershipRecovery.recover(
            store: store,
            ownerProcessIsCurrent: { _ in false },
            systemSleepIsDisabled: { true },
            authorizationIsInstalled: { false },
            restoreNormalSleep: {
                restoreCount += 1
                return true
            }
        )

        XCTAssertEqual(store.read(), record)
        XCTAssertEqual(restoreCount, 0)

        ClamshellOwnershipRecovery.recover(
            store: store,
            ownerProcessIsCurrent: { _ in false },
            systemSleepIsDisabled: { true },
            authorizationIsInstalled: { true },
            restoreNormalSleep: {
                restoreCount += 1
                return true
            }
        )

        XCTAssertNil(store.read())
        XCTAssertEqual(restoreCount, 1)
    }

    func testUnknownSystemStatusPreservesRecoveryProvenance() throws {
        let record = ClamshellOwnershipRecord(
            token: "status-unknown",
            processID: Int32.max,
            startedAt: Date()
        )
        try seed(record)
        var restoreCount = 0

        ClamshellOwnershipRecovery.recover(
            store: store,
            ownerProcessIsCurrent: { _ in false },
            systemSleepIsDisabled: { nil },
            authorizationIsInstalled: { true },
            restoreNormalSleep: {
                restoreCount += 1
                return true
            }
        )

        XCTAssertEqual(store.read(), record)
        XCTAssertEqual(restoreCount, 0)
    }

    func testUnknownSystemStatusBlocksClosedLidEnable() {
        XCTAssertEqual(
            ClamshellMode.enablePreflightFailure(
                systemStatusUnknown: true,
                externallyDisabled: false,
                authorized: true
            ),
            SteamPackL10n.text(
                "Could not verify the macOS sleep setting. Closed Lid was not enabled."
            )
        )
    }

    func testSystemStatusParserRequiresAnExactBooleanValue() {
        XCTAssertEqual(ClamshellMode.parseSystemStatus("SleepDisabled\t\t1\n"), true)
        XCTAssertEqual(ClamshellMode.parseSystemStatus("SleepDisabled 0\n"), false)
        XCTAssertNil(ClamshellMode.parseSystemStatus("SleepDisabled 10\n"))
        XCTAssertNil(ClamshellMode.parseSystemStatus("System-wide power settings:\n"))
    }

    func testAbandonedCurrentPIDLeaseRetriesAfterWatchdogRestoreFailure() throws {
        let processStart = try XCTUnwrap(ClamshellOwnershipStore.processStartDate(getpid()))
        let record = ClamshellOwnershipRecord(
            token: "watchdog-died",
            processID: getpid(),
            startedAt: Date(),
            processStartedAt: processStart
        )
        try seed(record)

        XCTAssertFalse(ClamshellWatchdog.restoreIfOwned(token: record.token, store: store) {
            false
        })
        XCTAssertEqual(store.read(), record)

        let activelyLeased = ClamshellMode.ownershipIsActivelyLeased(
            record: record,
            owningProcessIsLive: true,
            currentProcessID: getpid(),
            activeSessionToken: nil,
            watchdogToken: nil
        )
        XCTAssertFalse(activelyLeased)

        var retryCount = 0
        ClamshellOwnershipRecovery.recover(
            store: store,
            ownerProcessIsCurrent: { _ in activelyLeased },
            systemSleepIsDisabled: { true },
            authorizationIsInstalled: { true },
            restoreNormalSleep: {
                retryCount += 1
                return true
            }
        )

        XCTAssertEqual(retryCount, 1)
        XCTAssertNil(store.read())
    }

    func testWatchdogRestoresOnlyItsOwnLease() throws {
        let record = ClamshellOwnershipRecord(token: "current", processID: getpid(), startedAt: Date())
        try seed(record)
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
        try seed(record)

        XCTAssertFalse(ClamshellWatchdog.restoreIfOwned(token: "current", store: store) { false })
        XCTAssertNotNil(store.read())
    }
}
