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

    func testAppOriginatedControlReloadRetryIsShortAndBounded() {
        XCTAssertGreaterThan(
            SteamPackRuntimeRefreshPolicy.controlReloadRetryDelay,
            0
        )
        XCTAssertLessThanOrEqual(
            SteamPackRuntimeRefreshPolicy.controlReloadRetryDelay,
            2
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

    func testFirstControlPublicationReloadsBothControls() {
        let changes = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: false
        ).changedControls(comparedTo: nil)

        XCTAssertTrue(changes.keepAwake)
        XCTAssertTrue(changes.clamshell)
    }

    func testUnchangedControlStateDoesNotReload() {
        let state = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let changes = state.changedControls(comparedTo: state)

        XCTAssertFalse(changes.keepAwake)
        XCTAssertFalse(changes.clamshell)
    }

    func testClosedLidTransitionReloadsOnlyTheChangedSurface() {
        let keepAwake = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let closedLid = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: true
        )
        let changes = closedLid.changedControls(comparedTo: keepAwake)

        XCTAssertFalse(changes.keepAwake)
        XCTAssertTrue(changes.clamshell)
    }

    func testClosedLidAlwaysImpliesKeepAwake() {
        let state = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: true
        )

        XCTAssertTrue(state.keepAwake)
        XCTAssertTrue(state.clamshell)
    }

    func testFirstPublicationFailureReloadsBothControlsFailClosed() {
        let state = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let decision = SteamPackControlReloadDecision.decide(
            publicationSucceeded: false,
            publicationWasInvalid: false,
            reloadStateChanges: false,
            previous: state,
            current: state
        )

        XCTAssertEqual(decision, .both)
    }

    func testRepeatedPublicationFailureDoesNotFloodReloads() {
        let state = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let decision = SteamPackControlReloadDecision.decide(
            publicationSucceeded: false,
            publicationWasInvalid: true,
            reloadStateChanges: true,
            previous: nil,
            current: state
        )

        XCTAssertEqual(decision, .none)
    }

    func testPublicationRecoveryReloadsBothEvenWhenValuesDidNotChange() {
        let state = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let decision = SteamPackControlReloadDecision.decide(
            publicationSucceeded: true,
            publicationWasInvalid: true,
            reloadStateChanges: false,
            previous: state,
            current: state
        )

        XCTAssertEqual(decision, .both)
    }

    func testSuccessfulHeartbeatDoesNotReloadUnchangedControls() {
        let state = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: false
        )
        let decision = SteamPackControlReloadDecision.decide(
            publicationSucceeded: true,
            publicationWasInvalid: false,
            reloadStateChanges: false,
            previous: nil,
            current: state
        )

        XCTAssertEqual(decision, .none)
    }

    func testClosedLidControlReliesOnAutomaticSourceReloadAndReloadsSibling() {
        let normal = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: false
        )
        let closedLid = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: true
        )
        let decision = closedLid.changedControls(comparedTo: normal)
            .suppressingAutomaticReload(for: .clamshell)

        XCTAssertEqual(decision, SteamPackControlReloadDecision(
            keepAwake: true,
            clamshell: false
        ))
    }

    func testKeepAwakeOffReliesOnAutomaticSourceReloadAndReloadsClosedLidSibling() {
        let closedLid = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: true
        )
        let normal = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: false
        )
        let decision = normal.changedControls(comparedTo: closedLid)
            .suppressingAutomaticReload(for: .keepAwake)

        XCTAssertEqual(decision, SteamPackControlReloadDecision(
            keepAwake: false,
            clamshell: true
        ))
    }

    func testClosedLidOffNeedsNoManualReloadWhenSiblingStaysAwake() {
        let closedLid = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: true
        )
        let keepAwake = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: false
        )
        let decision = keepAwake.changedControls(comparedTo: closedLid)
            .suppressingAutomaticReload(for: .clamshell)

        XCTAssertEqual(decision, .none)
    }

    func testAppOriginatedTransitionReloadsEveryChangedControl() {
        let normal = SteamPackControlSurfaceState(
            keepAwake: false,
            clamshell: false
        )
        let closedLid = SteamPackControlSurfaceState(
            keepAwake: true,
            clamshell: true
        )
        let decision = closedLid.changedControls(comparedTo: normal)
            .suppressingAutomaticReload(for: nil)

        XCTAssertEqual(decision, .both)
    }

    func testClosedLidOffStartsKeepAwakeBeforeDisablingPMSet() {
        XCTAssertEqual(
            SteamPackKeepAwakeTransitionPlan.steps(
                keepAwakeIsOn: false,
                closedLidIsOn: true
            ),
            [.startKeepAwake, .disableClosedLid]
        )
        XCTAssertEqual(
            SteamPackKeepAwakeTransitionPlan.steps(
                keepAwakeIsOn: true,
                closedLidIsOn: true
            ),
            [.disableClosedLid]
        )
    }
}
