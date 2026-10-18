import XCTest
import QuotaCore
@testable import QuotaPhone

final class MonitoringSessionPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.simplifiedChinese)
    }
    override func tearDown() {
        L10n.resetLanguage()
        super.tearDown()
    }

    func testRetainedPhoneSnapshotStaysHistoricalUntilVerifiedRefresh() {
        var freshness = PhoneRefreshFreshness.verified
        XCTAssertFalse(freshness.isOffline)

        freshness.markCachedSnapshotLoaded()
        XCTAssertTrue(freshness.isOffline)

        freshness.markRefreshFailed()
        XCTAssertEqual(freshness, .retainedAfterFailure)
        XCTAssertTrue(freshness.isOffline)

        freshness.markRefreshSucceeded()
        XCTAssertEqual(freshness, .verified)
        XCTAssertFalse(freshness.isOffline)
    }

    private let start = Date(timeIntervalSince1970: 1_788_572_460)
    private let id = UUID(uuidString: "0FDE6DA0-6F9B-4A21-9EB4-C435B1C47A5E")!
    func testSystemDeadlineIsEightHoursWithoutAUserDuration() {
        let starting = MonitoringSessionPolicy.start(windowID: "codex-primary", now: start, id: id)!
        XCTAssertEqual(starting.session?.endsAt, start.addingTimeInterval(8 * 60 * 60))
        XCTAssertEqual(MonitoringSessionPolicy.systemActivityLifetime, 8 * 60 * 60)
    }

    func testSelectionOutlivesSystemDeadlineAndRelaunchWithoutRestartingAnActivity() {
        var selected = MonitoringSelection()
        XCTAssertTrue(selected.start(windowID: "codex-primary"))
        let status = MonitoringSessionPolicy.start(windowID: "codex-primary", now: start, id: id)!
        let session = status.session!
        let ended = MonitoringSessionPolicy.refresh(status, observedAt: start, staleAt: session.endsAt.addingTimeInterval(60), now: session.endsAt)
        XCTAssertEqual(ended, .ended(session, .systemEnded))
        XCTAssertTrue(MonitoringSessionPolicy.canUserStart(from: ended))
        let restored = MonitoringSelection(windowIDs: selected.windowIDs)
        XCTAssertEqual(restored.windowIDs, ["codex-primary"])
        XCTAssertEqual(restored.rowState(windowID: "codex-primary", runningWindowIDs: [], offline: false, stale: false), .systemEnded)
        XCTAssertEqual(MonitoringSessionPolicy.refresh(ended, observedAt: session.endsAt, staleAt: session.endsAt.addingTimeInterval(600), now: session.endsAt.addingTimeInterval(1)), ended)
    }

    func testRepeatedStartCannotDuplicateSelectionOrRunningWindow() {
        var selected = MonitoringSelection()
        XCTAssertTrue(selected.start(windowID: "first"))
        XCTAssertTrue(selected.start(windowID: "first"))
        XCTAssertTrue(selected.start(windowID: "second"))
        XCTAssertFalse(selected.start(windowID: "third"))
        XCTAssertFalse(selected.start(windowID: ""))
        XCTAssertEqual(selected.windowIDs, ["first", "second"])
        XCTAssertFalse(MonitoringSessionPolicy.canStart(windowID: "first", activeWindowIDs: ["first"]))
    }

    func testManualStopPersistsAcrossRelaunchAndRefresh() {
        var selected = MonitoringSelection(windowIDs: ["first", "second"])
        selected.stop(windowID: "first")
        let restored = MonitoringSelection(windowIDs: selected.windowIDs)
        XCTAssertEqual(restored.windowIDs, ["second"])
        XCTAssertEqual(restored.rowState(windowID: "first", runningWindowIDs: [], offline: false, stale: false), .off)
        // An activity still awaiting async cleanup cannot restore user intent.
        XCTAssertEqual(restored.rowState(windowID: "first", runningWindowIDs: ["first"], offline: false, stale: false), .off)
        XCTAssertTrue(MonitoringSessionPolicy.canStart(windowID: "third", activeWindowIDs: restored.windowIDs))
    }

    func testExplicitRestartCreatesANewSystemBoundedSession() {
        let old = MonitoringSessionPolicy.start(windowID: "first", now: start, id: id)!.session!
        let restartedAt = old.endsAt.addingTimeInterval(60)
        let restarted = MonitoringSessionPolicy.start(windowID: "first", now: restartedAt)!.session!
        XCTAssertNotEqual(old.id, restarted.id)
        XCTAssertEqual(restarted.windowID, old.windowID)
        XCTAssertEqual(restarted.endsAt, restartedAt.addingTimeInterval(8 * 60 * 60))
        let selected = MonitoringSelection(windowIDs: ["first"])
        XCTAssertEqual(selected.rowState(windowID: "first", runningWindowIDs: ["first"], offline: false, stale: false), .live)
    }

    func testDisplayActionsAndStatusRemainTruthfulDuringOfflineAndSystemEnd() {
        let selected = MonitoringSelection(windowIDs: ["first"])
        XCTAssertEqual(selected.rowState(windowID: "first", runningWindowIDs: ["first"], offline: true, stale: true), .offline)
        XCTAssertEqual(selected.rowState(windowID: "first", runningWindowIDs: ["first"], offline: false, stale: true), .stale)
        XCTAssertEqual(selected.rowState(windowID: "first", runningWindowIDs: [], offline: true, stale: true), .systemEnded)
        XCTAssertEqual(MonitoringRowState.off.primaryActionTitle, "显示到锁屏")
        XCTAssertEqual(MonitoringRowState.live.primaryActionTitle, "停止显示")
        XCTAssertEqual(MonitoringRowState.systemEnded.primaryActionTitle, "重新显示")
    }

    func testSavedEmptySelectionPreventsAdoptionOfACardStillAwaitingStop() {
        XCTAssertEqual(MonitoringSelection.restored(savedWindowIDs: [], runningWindowIDs: ["first"]).windowIDs, [])
        XCTAssertEqual(MonitoringSelection.restored(savedWindowIDs: ["second"], runningWindowIDs: ["first"]).windowIDs, ["second"])
        XCTAssertEqual(MonitoringSelection.restored(savedWindowIDs: nil, runningWindowIDs: ["first"]).windowIDs, ["first"])
    }

    func testInterruptedStopReconcilesSurvivingCardBeforeRecovery() {
        var selected = MonitoringSelection(windowIDs: ["first", "second"])
        selected.stop(windowID: "first")
        let relaunched = MonitoringSelection.restored(savedWindowIDs: selected.windowIDs, runningWindowIDs: ["first", "second"])
        XCTAssertTrue(relaunched.shouldEndExistingActivity(windowID: "first"), "Surviving stopped card must end instead of being updated or registered")
        XCTAssertFalse(relaunched.shouldEndExistingActivity(windowID: "second"))
        let stoppedAll = MonitoringSelection.restored(savedWindowIDs: [], runningWindowIDs: ["first"])
        XCTAssertTrue(stoppedAll.shouldEndExistingActivity(windowID: "first"))
        let legacy = MonitoringSelection.restored(savedWindowIDs: nil, runningWindowIDs: ["first"])
        XCTAssertFalse(legacy.shouldEndExistingActivity(windowID: "first"))
    }

    func testMissingSnapshotAndEndedActivitiesKeepSelectionsStoppable() {
        let selected = MonitoringSelection(windowIDs: ["first", "second"])
        XCTAssertTrue(selected.showsDisplayControls(availableWindowCount: 0, runningActivityCount: 0))
        XCTAssertFalse(MonitoringSelection().showsDisplayControls(availableWindowCount: 0, runningActivityCount: 0))
        XCTAssertTrue(MonitoringSelection().showsDisplayControls(availableWindowCount: 1, runningActivityCount: 0))
    }

    @MainActor
    func testRestartSuspendedForCleanupCannotRecreateRemovedOrRevokedSource() async {
        let selected = MonitoringSelection(windowIDs: ["first"])
        var available = ["first"]
        var resume: CheckedContinuation<Void, Never>?
        let restart = Task {
            await withCheckedContinuation { resume = $0 }
            return selected.canRestart(windowID: "first", availableWindowIDs: available, sourceUnchanged: true, ready: true)
        }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        available = [] // A refresh removes the source while cleanup is suspended.
        resume?.resume()
        let permitted = await restart.value
        XCTAssertFalse(permitted)
        XCTAssertFalse(selected.canRestart(windowID: "first", availableWindowIDs: ["first"], sourceUnchanged: false, ready: true))
        XCTAssertFalse(selected.canRestart(windowID: "first", availableWindowIDs: ["first"], sourceUnchanged: true, ready: false))
        XCTAssertTrue(selected.canRestart(windowID: "first", availableWindowIDs: ["first"], sourceUnchanged: true, ready: true))
    }

    func testLegacySelectionsNormalizeWithoutStartingActivities() {
        XCTAssertEqual(MonitoringSelection(windowIDs: ["", "first", "first", "second", "third"]).windowIDs, ["first", "second"])
    }

    func testFreshObservationRecoversStaleBeforeSessionEnd() {
        let starting = MonitoringSessionPolicy.start(windowID: "codex-primary", now: start, id: id)!
        guard let session = starting.session else { return XCTFail("expected session") }
        let stale = MonitoringSessionPolicy.refresh(starting, observedAt: start, staleAt: start, now: start.addingTimeInterval(1))
        XCTAssertEqual(stale, .stale(session))
        let active = MonitoringSessionPolicy.refresh(stale, observedAt: start.addingTimeInterval(2), staleAt: start.addingTimeInterval(600), now: start.addingTimeInterval(3))
        XCTAssertEqual(active, .active(session))
    }

    func testEmptyWindowCannotStartMonitoring() {
        XCTAssertNil(MonitoringSessionPolicy.start(windowID: "", now: start, id: id))
    }

    func testTwoIndependentWindowsMayRunWithoutDuplicatingOneWindow() {
        XCTAssertTrue(MonitoringSessionPolicy.canStart(windowID: "second", activeWindowIDs: ["first"]))
        XCTAssertFalse(MonitoringSessionPolicy.canStart(windowID: "third", activeWindowIDs: ["first", "second"]))
        XCTAssertFalse(MonitoringSessionPolicy.canStart(windowID: "second", activeWindowIDs: ["first", "second"]))
        XCTAssertFalse(MonitoringSessionPolicy.canStart(windowID: "fifth", activeWindowIDs: ["first", "second", "third", "fourth"]))
    }

    func testRefreshCannotReviveEndedOrDismissedSession() {
        let starting = MonitoringSessionPolicy.start(windowID: "codex-primary", now: start, id: id)!
        guard let session = starting.session else { return XCTFail("expected session") }
        for terminal in [
            MonitoringSessionStatus.ended(session, .userEnded),
            MonitoringSessionStatus.ended(session, .systemEnded),
            MonitoringSessionStatus.dismissed(session)
        ] {
            XCTAssertEqual(
                MonitoringSessionPolicy.refresh(terminal, observedAt: start, staleAt: start.addingTimeInterval(600), now: start.addingTimeInterval(1)),
                terminal
            )
        }
    }
}
