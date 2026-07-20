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
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            now: now
        ))

        XCTAssertTrue(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
    }

    func testAppliedModesAreReadFromOneAtomicRecord() throws {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: now
        ))

        // Contradictory legacy files cannot split a state once the new record exists.
        try "0".write(
            to: SteamPackShared.stateFileURL("applied-keep-awake.state"),
            atomically: true,
            encoding: .utf8
        )
        try "0".write(
            to: SteamPackShared.stateFileURL("applied-clamshell.state"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            SteamPackShared.readAppliedState(now: now),
            SteamPackAppliedState(
                keepAwake: true,
                clamshell: true,
                updatedAt: now
            )
        )
    }

    func testAppliedRequestRevisionAcknowledgesTheExactControlRequest() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 42,
            updatedAt: now
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 41,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: request,
                now: now
            ),
            .pending
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 42,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: request,
                now: now
            ),
            .applied
        )
    }

    func testAcknowledgedButUnappliedControlRequestIsRejected() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: true,
            revision: 7,
            updatedAt: now
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 7,
            now: now
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: request,
                now: now
            ),
            .rejected
        )
    }

    func testNewerAppliedRevisionSupersedesAnOlderRapidTap() {
        let now = Date()
        let oldRequest = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 10,
            updatedAt: now,
            source: .keepAwake
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 11,
            requestSource: .keepAwake,
            requestSucceeded: true,
            now: now
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: oldRequest,
                now: now
            ),
            .superseded
        )
    }

    func testNewerLocalRevisionRejectsAnOlderRapidTap() {
        let now = Date()
        let oldRequest = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 10,
            updatedAt: now,
            source: .keepAwake
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 11,
            now: now
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: oldRequest, now: now),
            .rejected
        )
    }

    func testNewerFailedControlRequestRejectsAnOlderRapidTap() {
        let now = Date()
        let oldRequest = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 10,
            updatedAt: now,
            source: .keepAwake
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 11,
            requestSource: .clamshell,
            requestSucceeded: false,
            now: now
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: oldRequest, now: now),
            .rejected
        )
    }

    func testExplicitFailedAcknowledgementRejectsMatchingBooleans() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 12,
            updatedAt: now,
            source: .keepAwake
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 12,
            requestSource: .keepAwake,
            requestSucceeded: false,
            now: now
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .rejected
        )
    }

    func testControlAcknowledgementRequiresMatchingSourceAndExplicitSuccess() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 14,
            updatedAt: now,
            source: .keepAwake,
            rollbackKeepAwake: false,
            rollbackClamshell: false,
            expiresAt: now.addingTimeInterval(5)
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 14,
            requestSucceeded: true,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .pending
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 14,
            requestSource: .clamshell,
            requestSucceeded: true,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .rejected
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 14,
            requestSource: .keepAwake,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .pending
        )

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 14,
            requestSource: .keepAwake,
            requestSucceeded: true,
            now: now
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .applied
        )
    }

    func testFailedSuccessPublicationRecoversOnlyAsRejection() throws {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 15,
            updatedAt: now,
            source: .keepAwake,
            rollbackKeepAwake: false,
            rollbackClamshell: false,
            expiresAt: now.addingTimeInterval(5)
        )
        let appliedURL = SteamPackShared.stateFileURL("applied-state.json")
        try FileManager.default.createDirectory(
            at: appliedURL,
            withIntermediateDirectories: true
        )

        XCTAssertFalse(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 15,
            requestSource: .keepAwake,
            requestSucceeded: true,
            now: now
        ))
        XCTAssertNil(SteamPackShared.readAppliedState(now: now))

        // Production code deliberately does not unlink a failed destination on
        // the main thread. Model the external/storage condition recovering
        // before the app publishes the durable rejection.
        try FileManager.default.removeItem(at: appliedURL)
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 15,
            requestSource: .keepAwake,
            requestSucceeded: false,
            now: now.addingTimeInterval(0.001)
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: request,
                now: now.addingTimeInterval(0.001)
            ),
            .rejected
        )
    }

    func testAcknowledgementRequiresAcceptanceFreshnessAndCompleteMode() throws {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: true,
            revision: 13,
            updatedAt: now,
            source: .clamshell,
            rollbackKeepAwake: false,
            rollbackClamshell: false,
            expiresAt: now.addingTimeInterval(5)
        )

        XCTAssertEqual(
            SteamPackControlAcknowledgement.evaluate(
                request: request,
                acceptedIncomingRequest: true,
                appliedKeepAwake: false,
                appliedClamshell: true,
                now: now
            ),
            SteamPackControlAcknowledgement(
                requestRevision: 13,
                source: .clamshell,
                succeeded: true
            )
        )
        XCTAssertFalse(try XCTUnwrap(SteamPackControlAcknowledgement.evaluate(
            request: request,
            acceptedIncomingRequest: false,
            appliedKeepAwake: true,
            appliedClamshell: true,
            now: now
        )).succeeded)
        XCTAssertFalse(try XCTUnwrap(SteamPackControlAcknowledgement.evaluate(
            request: request,
            acceptedIncomingRequest: true,
            appliedKeepAwake: true,
            appliedClamshell: false,
            now: now
        )).succeeded)
        XCTAssertFalse(try XCTUnwrap(SteamPackControlAcknowledgement.evaluate(
            request: request,
            acceptedIncomingRequest: true,
            appliedKeepAwake: true,
            appliedClamshell: true,
            now: now.addingTimeInterval(5)
        )).succeeded)
    }

    func testLegacyAppliedStateWithoutRevisionCannotFalselyAcknowledgeRequest() throws {
        let now = Date()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        {"keepAwake":true,"clamshell":false,"updatedAt":\(now.timeIntervalSinceReferenceDate)}
        """
        try Data(legacyJSON.utf8).write(
            to: SteamPackShared.stateFileURL("applied-state.json"),
            options: .atomic
        )
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 1,
            updatedAt: now
        )

        XCTAssertEqual(
            SteamPackShared.appliedStatus(
                for: request,
                now: now
            ),
            .pending
        )
    }

    func testControlRequestCapturesSourceRollbackDeadlineAndRevisionFloor() throws {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 10,
            now: now
        ))

        let request = try XCTUnwrap(SteamPackShared.requestClamshellRecord(true))
        XCTAssertEqual(request.source, .clamshell)
        XCTAssertEqual(request.rollbackKeepAwake, false)
        XCTAssertEqual(request.rollbackClamshell, false)
        XCTAssertEqual(request.revision, 11)
        XCTAssertGreaterThan(try XCTUnwrap(request.expiresAt), request.updatedAt)
        XCTAssertEqual(SteamPackShared.readControlRequest(), request)
    }

    func testFullModeMustMatchBeforeLinkedControlRequestSucceeds() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 7,
            updatedAt: now,
            source: .clamshell,
            rollbackKeepAwake: true,
            rollbackClamshell: true,
            expiresAt: now.addingTimeInterval(5)
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: 7,
            requestSource: .clamshell,
            requestSucceeded: true,
            now: now
        ))

        // The tapped Closed Lid Boolean matches false, but Keep Awake failed.
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: now),
            .rejected
        )
    }

    func testAcknowledgementWrittenAfterRequestDeadlineIsRejected() {
        let now = Date()
        let deadline = now.addingTimeInterval(1)
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 8,
            updatedAt: now,
            source: .keepAwake,
            rollbackKeepAwake: false,
            rollbackClamshell: false,
            expiresAt: deadline
        )
        let late = deadline.addingTimeInterval(0.001)
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: false,
            requestRevision: 8,
            requestSource: .keepAwake,
            requestSucceeded: true,
            now: late
        ))

        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: request, now: late),
            .rejected
        )
    }

    func testRequestExpiryBoundaryIsExplicit() {
        let now = Date()
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: false,
            revision: 1,
            updatedAt: now,
            source: .keepAwake,
            rollbackKeepAwake: false,
            rollbackClamshell: false,
            expiresAt: now.addingTimeInterval(5)
        )

        XCTAssertFalse(request.isExpired(now: now.addingTimeInterval(4.999)))
        XCTAssertTrue(request.isExpired(now: now.addingTimeInterval(5)))
    }

    func testTimedOutRequestRollsBackOnlyItsExactRevision() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let timedOut = try XCTUnwrap(SteamPackShared.requestClamshellRecord(true))

        guard case .written(let rollback) =
                SteamPackShared.cancelTimedOutControlRequest(timedOut) else {
            return XCTFail("timeout rollback was not written")
        }
        XCTAssertGreaterThan(rollback.revision, timedOut.revision)
        XCTAssertFalse(rollback.keepAwake)
        XCTAssertFalse(rollback.clamshell)
        XCTAssertNil(rollback.source)
        XCTAssertNil(rollback.expiresAt)

        guard case .conflict(let current) =
                SteamPackShared.cancelTimedOutControlRequest(timedOut) else {
            return XCTFail("a second rollback overwrote the newer record")
        }
        XCTAssertEqual(current, rollback)
        XCTAssertEqual(SteamPackShared.readControlRequest(), rollback)
    }

    func testNewerControlRequestWinsOverTimeoutRollback() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let older = try XCTUnwrap(SteamPackShared.requestClamshellRecord(true))
        let newer = try XCTUnwrap(SteamPackShared.requestKeepAwakeRecord(false))

        guard case .conflict(let current) =
                SteamPackShared.cancelTimedOutControlRequest(older) else {
            return XCTFail("timeout rollback replaced a newer tap")
        }
        XCTAssertEqual(current, newer)
        XCTAssertEqual(SteamPackShared.readControlRequest(), newer)
    }

    func testCorruptRequestCannotResetRevisionOrBeOverwritten() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let initial = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: false,
            clamshell: false
        ))
        let requestURL = SteamPackShared.stateFileURL("control-request.json")
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: requestURL, options: .atomic)

        XCTAssertNil(SteamPackShared.requestKeepAwakeRecord(true))
        XCTAssertEqual(try Data(contentsOf: requestURL), corrupt)

        try FileManager.default.removeItem(at: requestURL)
        let recovered = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: false,
            clamshell: false
        ))
        XCTAssertGreaterThan(recovered.revision, initial.revision)
    }

    func testFreshAtomicOffSupersedesPriorOnAndStaleLegacyFiles() throws {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: now
        ))
        try "1".write(
            to: SteamPackShared.stateFileURL("applied-keep-awake.state"),
            atomically: true,
            encoding: .utf8
        )
        try "1".write(
            to: SteamPackShared.stateFileURL("applied-clamshell.state"),
            atomically: true,
            encoding: .utf8
        )

        let offTime = now.addingTimeInterval(1)
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            now: offTime
        ))
        let applied = try XCTUnwrap(SteamPackShared.readAppliedState(now: offTime))
        XCTAssertFalse(applied.keepAwake)
        XCTAssertFalse(applied.clamshell)
        XCTAssertTrue(SteamPackShared.isAppAlive(now: offTime))
    }

    func testUnreadableAppliedDestinationFailsClosedAfterWriteFailure() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: now
        ))

        let appliedURL = SteamPackShared.stateFileURL("applied-state.json")
        try FileManager.default.removeItem(at: appliedURL)
        try FileManager.default.createDirectory(
            at: appliedURL,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            now: now.addingTimeInterval(1)
        ))
        XCTAssertNil(SteamPackShared.readAppliedState(now: now.addingTimeInterval(1)))
        XCTAssertFalse(SteamPackShared.isAppAlive(now: now.addingTimeInterval(1)))
    }

    func testCorruptAppliedRecordFailsClosedInsteadOfUsingLegacyFiles() throws {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishHeartbeat(now: now))
        try "1".write(
            to: SteamPackShared.stateFileURL("applied-keep-awake.state"),
            atomically: true,
            encoding: .utf8
        )
        try Data("not-json".utf8).write(
            to: SteamPackShared.stateFileURL("applied-state.json"),
            options: .atomic
        )

        XCTAssertNil(SteamPackShared.readAppliedState(now: now))
        XCTAssertFalse(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
    }

    func testLegacyAppliedFilesAreReadUntilAtomicRecordIsPublished() throws {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishHeartbeat(now: now))
        try "0".write(
            to: SteamPackShared.stateFileURL("applied-keep-awake.state"),
            atomically: true,
            encoding: .utf8
        )
        try "1".write(
            to: SteamPackShared.stateFileURL("applied-clamshell.state"),
            atomically: true,
            encoding: .utf8
        )

        // A legacy Double timestamp is text-encoded, so allow the next read to
        // occur just after the recorded instant as it does in the running app.
        let migrated = try XCTUnwrap(SteamPackShared.readAppliedState(
            now: now.addingTimeInterval(0.001)
        ))
        XCTAssertTrue(migrated.keepAwake)
        XCTAssertTrue(migrated.clamshell)
        XCTAssertEqual(migrated.updatedAt.timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testLaunchClearPreventsFreshCrashHeartbeatFromRevivingOldState() {
        let crashTime = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: crashTime
        ))
        XCTAssertTrue(SteamPackShared.readAppliedKeepAwake())

        XCTAssertTrue(SteamPackShared.clearHeartbeat())

        XCTAssertFalse(SteamPackShared.isAppAlive(now: crashTime))
        XCTAssertFalse(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
        let appliedURL = SteamPackShared.stateFileURL("applied-state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appliedURL.path))
        let tombstone = try? JSONDecoder().decode(
            SteamPackAppliedState.self,
            from: Data(contentsOf: appliedURL)
        )
        XCTAssertEqual(tombstone?.updatedAt, .distantPast)
    }

    func testStaleAppliedRecordMakesProviderStateUnavailable() {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: now.addingTimeInterval(-10)
        ))

        XCTAssertNil(SteamPackShared.readAppliedState(now: now))
        XCTAssertFalse(SteamPackShared.isAppAlive(now: now))
        XCTAssertFalse(SteamPackShared.readAppliedKeepAwake())
        XCTAssertFalse(SteamPackShared.readAppliedClamshell())
    }

    func testLegacyHeartbeatCannotRefreshAStaleAtomicRecord() {
        let now = Date()
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            now: now.addingTimeInterval(-10)
        ))
        XCTAssertTrue(SteamPackShared.publishHeartbeat(now: now))

        XCTAssertNil(SteamPackShared.readAppliedState(now: now))
        XCTAssertFalse(SteamPackShared.isAppAlive(now: now))
    }

    func testRequestIsRejectedWhenAppIsNotAlive() {
        SteamPackShared.clearHeartbeat()
        XCTAssertFalse(SteamPackShared.requestClamshell(true))
        XCTAssertFalse(SteamPackShared.requestKeepAwake(true))
    }

    func testClosedLidOffRebasesAfterRejectedKeepAwakeRequest() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true
        ))
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: true, clamshell: true))

        let rejectedKeepAwake = try XCTUnwrap(
            SteamPackShared.requestKeepAwakeRecord(false)
        )
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: true,
            clamshell: true,
            requestRevision: rejectedKeepAwake.revision,
            requestSource: .keepAwake,
            requestSucceeded: false
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: rejectedKeepAwake),
            .rejected
        )

        let closedLidOff = try XCTUnwrap(
            SteamPackShared.requestClamshellRecord(false)
        )
        XCTAssertTrue(closedLidOff.keepAwake)
        XCTAssertFalse(closedLidOff.clamshell)

        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: closedLidOff.keepAwake,
                requestedClamshell: closedLidOff.clamshell
            ),
            .keepAwake
        )
    }

    func testKeepAwakeRebasesAfterRejectedClosedLidRequest() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let rejectedClosedLid = try XCTUnwrap(
            SteamPackShared.requestClamshellRecord(true)
        )
        XCTAssertTrue(rejectedClosedLid.keepAwake)
        XCTAssertTrue(rejectedClosedLid.clamshell)

        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false,
            requestRevision: rejectedClosedLid.revision,
            requestSource: .clamshell,
            requestSucceeded: false
        ))
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: rejectedClosedLid),
            .rejected
        )

        let keepAwake = try XCTUnwrap(
            SteamPackShared.requestKeepAwakeRecord(true)
        )
        XCTAssertEqual(keepAwake.source, .keepAwake)
        XCTAssertTrue(keepAwake.keepAwake)
        XCTAssertFalse(keepAwake.clamshell)
        XCTAssertEqual(keepAwake.rollbackKeepAwake, false)
        XCTAssertEqual(keepAwake.rollbackClamshell, false)
    }

    func testRapidKeepAwakeOnComposesWithPendingClosedLidOn() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let pendingClosedLid = try XCTUnwrap(
            SteamPackShared.requestClamshellRecord(true)
        )
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: pendingClosedLid),
            .pending
        )

        let keepAwake = try XCTUnwrap(
            SteamPackShared.requestKeepAwakeRecord(true)
        )
        XCTAssertGreaterThan(keepAwake.revision, pendingClosedLid.revision)
        XCTAssertEqual(keepAwake.source, .keepAwake)
        XCTAssertTrue(keepAwake.keepAwake)
        XCTAssertTrue(keepAwake.clamshell)
        XCTAssertEqual(keepAwake.rollbackKeepAwake, false)
        XCTAssertEqual(keepAwake.rollbackClamshell, false)
    }

    func testRapidClosedLidOffComposesWithPendingKeepAwakeOn() throws {
        XCTAssertTrue(SteamPackShared.publishApplied(
            keepAwake: false,
            clamshell: false
        ))
        let pendingKeepAwake = try XCTUnwrap(
            SteamPackShared.requestKeepAwakeRecord(true)
        )
        XCTAssertEqual(
            SteamPackShared.appliedStatus(for: pendingKeepAwake),
            .pending
        )

        let closedLid = try XCTUnwrap(
            SteamPackShared.requestClamshellRecord(false)
        )
        XCTAssertGreaterThan(closedLid.revision, pendingKeepAwake.revision)
        XCTAssertEqual(closedLid.source, .clamshell)
        XCTAssertTrue(closedLid.keepAwake)
        XCTAssertFalse(closedLid.clamshell)
        XCTAssertEqual(closedLid.rollbackKeepAwake, false)
        XCTAssertEqual(closedLid.rollbackClamshell, false)
    }

    func testClosedLidOffPreservesAnExplicitKeepAwakeRequest() {
        SteamPackShared.publishApplied(keepAwake: true, clamshell: true)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: true, clamshell: true))

        XCTAssertTrue(SteamPackShared.requestClamshell(false))

        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: SteamPackShared.readRequestedKeepAwake(),
                requestedClamshell: SteamPackShared.readRequestedClamshell()
            ),
            .keepAwake
        )
    }

    func testClosedLidOnAlsoRequestsKeepAwake() {
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))

        XCTAssertTrue(SteamPackShared.requestClamshell(true))

        XCTAssertTrue(SteamPackShared.readRequestedKeepAwake())
        XCTAssertTrue(SteamPackShared.readRequestedClamshell())
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: SteamPackShared.readRequestedKeepAwake(),
                requestedClamshell: SteamPackShared.readRequestedClamshell()
            ),
            .closedLid
        )
    }

    func testLateNotificationReconcilesNewestAtomicRequest() {
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))

        XCTAssertTrue(SteamPackShared.requestClamshell(true))
        let olderRequest = SteamPackShared.readControlRequest()
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: olderRequest.keepAwake,
                requestedClamshell: olderRequest.clamshell
            ),
            .closedLid
        )

        XCTAssertTrue(SteamPackShared.requestKeepAwake(false))
        let newestRequestReadByEitherNotification = SteamPackShared.readControlRequest()

        XCTAssertGreaterThan(newestRequestReadByEitherNotification.revision, olderRequest.revision)
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: newestRequestReadByEitherNotification.keepAwake,
                requestedClamshell: newestRequestReadByEitherNotification.clamshell
            ),
            .normalSleep
        )
    }

    func testConcurrentControlWritesRemainCompleteAndRevisioned() {
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))
        let initialRevision = SteamPackShared.readControlRequest().revision
        let successLock = NSLock()
        var successCount = 0

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let succeeded = index.isMultiple(of: 2)
                ? SteamPackShared.requestClamshell(true)
                : SteamPackShared.requestKeepAwake(false)
            if succeeded {
                successLock.lock()
                successCount += 1
                successLock.unlock()
            }
        }

        let finalRequest = SteamPackShared.readControlRequest()
        XCTAssertEqual(successCount, 40)
        XCTAssertEqual(finalRequest.revision, initialRevision + 40)
        XCTAssertFalse(finalRequest.clamshell && !finalRequest.keepAwake)
    }

    func testLateControlNotificationCannotUndoNewerLocalIntent() {
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))

        XCTAssertTrue(SteamPackShared.requestClamshell(true))
        let controlRequest = SteamPackShared.readControlRequest()

        // A later successful menu/timer/safety/watchdog action publishes a new
        // local intent before an older Darwin notification is delivered.
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))
        let requestReadByLateNotification = SteamPackShared.readControlRequest()

        XCTAssertGreaterThan(requestReadByLateNotification.revision, controlRequest.revision)
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: requestReadByLateNotification.keepAwake,
                requestedClamshell: requestReadByLateNotification.clamshell
            ),
            .normalSleep
        )
    }

    func testFailedLocalOffKeepsDesiredIntentOffAndReportsFailure() {
        SteamPackShared.publishApplied(keepAwake: false, clamshell: false)
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))
        XCTAssertTrue(SteamPackShared.requestClamshell(true))

        let report = SteamPackStopReport(attempts: [
            .failed("normal sleep was not restored")
        ])
        XCTAssertTrue(SteamPackShared.resetControlRequest(keepAwake: false, clamshell: false))
        let desiredAfterFailure = SteamPackShared.readControlRequest()

        XCTAssertEqual(report.failures, ["normal sleep was not restored"])
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: desiredAfterFailure.keepAwake,
                requestedClamshell: desiredAfterFailure.clamshell
            ),
            .normalSleep
        )
    }

    func testFailedLocalOffWriteStillDominatesALateNotification() throws {
        let initial = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: true,
            clamshell: true
        ))
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.normalSleep, throughRevision: initial.revision)

        // Make the cross-process lock path unusable without changing the already
        // persisted ON request. This deterministically exercises a write failure.
        let lockURL = SteamPackShared.stateFileURL("control-request.lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        XCTAssertNil(SteamPackShared.resetControlRequestRecord(
            keepAwake: false,
            clamshell: false
        ))

        let staleRequestReadByLateNotification = SteamPackShared.readControlRequest()
        let staleResolution = barrier.resolve(staleRequestReadByLateNotification)
        XCTAssertEqual(staleResolution.mode, .normalSleep)
        XCTAssertFalse(staleResolution.acceptedIncomingRequest)

        // Once persistence works again, a truly newer Control Center request must
        // cross the barrier instead of being mistaken for the stale ON record.
        try FileManager.default.removeItem(at: lockURL)
        let newerRequest = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: true,
            clamshell: false
        ))
        let newerResolution = barrier.resolve(newerRequest)
        XCTAssertGreaterThan(newerRequest.revision, initial.revision)
        XCTAssertEqual(newerResolution.mode, .keepAwake)
        XCTAssertTrue(newerResolution.acceptedIncomingRequest)
        XCTAssertNil(barrier.pendingIntent)
    }

    func testPersistedLocalIntentAlsoRejectsOlderNotifications() throws {
        let oldRequest = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: true,
            clamshell: true
        ))
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.normalSleep, throughRevision: oldRequest.revision)
        let persistedOff = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: false,
            clamshell: false
        ))
        XCTAssertTrue(barrier.markPersisted(persistedOff))

        let resolution = barrier.resolve(oldRequest)
        XCTAssertEqual(resolution.mode, .normalSleep)
        XCTAssertFalse(resolution.acceptedIncomingRequest)
        XCTAssertEqual(
            barrier.pendingIntent?.throughRevision,
            persistedOff.revision
        )
    }

    func testExpiredRequestCanBeAddedToPendingLocalIntentBarrier() {
        let request = SteamPackControlRequest(
            keepAwake: true,
            clamshell: true,
            revision: 22,
            updatedAt: Date(),
            source: .clamshell
        )
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.normalSleep, throughRevision: 21)

        XCTAssertTrue(barrier.extendPendingIntent(
            throughRevision: request.revision
        ))
        XCTAssertEqual(barrier.pendingIntent?.throughRevision, 22)
        let resolution = barrier.resolve(request)
        XCTAssertFalse(resolution.acceptedIncomingRequest)
        XCTAssertEqual(resolution.mode, .normalSleep)
    }

    func testExternalOffAdvancesRevisionAndLateClosedLidRequestCannotRevive() throws {
        let oldClosedLidRequest = try XCTUnwrap(
            SteamPackShared.resetControlRequestRecord(
                keepAwake: true,
                clamshell: true
            )
        )
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.normalSleep, throughRevision: oldClosedLidRequest.revision)

        let writeResult = SteamPackShared.compareAndResetControlRequest(
            keepAwake: false,
            clamshell: false,
            ifCurrentRevisionAtMost: oldClosedLidRequest.revision
        )
        guard case .written(let persistedOff) = writeResult else {
            return XCTFail("external OFF intent was not persisted")
        }
        XCTAssertTrue(barrier.markPersisted(persistedOff))
        XCTAssertGreaterThan(persistedOff.revision, oldClosedLidRequest.revision)
        XCTAssertEqual(
            SteamPackControlPolicy.desiredMode(
                requestedKeepAwake: persistedOff.keepAwake,
                requestedClamshell: persistedOff.clamshell
            ),
            .normalSleep
        )

        let lateResolution = barrier.resolve(oldClosedLidRequest)
        XCTAssertFalse(lateResolution.acceptedIncomingRequest)
        XCTAssertEqual(lateResolution.mode, .normalSleep)
    }

    func testExternalClosedLidDisarmPersistsRemainingKeepAwakeMode() throws {
        let oldClosedLidRequest = try XCTUnwrap(
            SteamPackShared.resetControlRequestRecord(
                keepAwake: true,
                clamshell: true
            )
        )
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.keepAwake, throughRevision: oldClosedLidRequest.revision)

        let writeResult = SteamPackShared.compareAndResetControlRequest(
            keepAwake: true,
            clamshell: false,
            ifCurrentRevisionAtMost: oldClosedLidRequest.revision
        )
        guard case .written(let persistedKeepAwake) = writeResult else {
            return XCTFail("partial external disarm was not persisted")
        }
        XCTAssertTrue(barrier.markPersisted(persistedKeepAwake))
        XCTAssertGreaterThan(
            persistedKeepAwake.revision,
            oldClosedLidRequest.revision
        )

        let lateResolution = barrier.resolve(oldClosedLidRequest)
        XCTAssertFalse(lateResolution.acceptedIncomingRequest)
        XCTAssertEqual(lateResolution.mode, .keepAwake)
    }

    func testRetryCASDoesNotOverwriteANewerExtensionRequest() throws {
        let initial = try XCTUnwrap(SteamPackShared.resetControlRequestRecord(
            keepAwake: true,
            clamshell: true
        ))
        var barrier = SteamPackLocalIntentBarrier()
        barrier.begin(.normalSleep, throughRevision: initial.revision)

        // This write lands after the local OFF barrier but immediately before its
        // retry reaches the locked compare-and-set mutation.
        let newerExtensionRequest = try XCTUnwrap(
            SteamPackShared.resetControlRequestRecord(
                keepAwake: true,
                clamshell: false
            )
        )
        let retryResult = SteamPackShared.compareAndResetControlRequest(
            keepAwake: false,
            clamshell: false,
            ifCurrentRevisionAtMost: initial.revision
        )

        XCTAssertEqual(retryResult, .conflict(newerExtensionRequest))
        XCTAssertEqual(SteamPackShared.readControlRequest(), newerExtensionRequest)
        let resolution = barrier.resolve(newerExtensionRequest)
        XCTAssertTrue(resolution.acceptedIncomingRequest)
        XCTAssertEqual(resolution.mode, .keepAwake)
        XCTAssertNil(barrier.pendingIntent)
    }

    func testStopReportPreservesEveryFailureForControlCenterFeedback() {
        let report = SteamPackStopReport(attempts: [
            .failed("caffeinate did not stop"),
            .success,
            .failed("normal sleep was not restored")
        ])

        XCTAssertEqual(report.failures, [
            "caffeinate did not stop",
            "normal sleep was not restored"
        ])
    }
}
