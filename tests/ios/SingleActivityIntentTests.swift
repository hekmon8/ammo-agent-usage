import XCTest
import Foundation
import QuotaPhone

final class SingleActivityIntentTests: XCTestCase {
    func testStopInvalidatesSuspendedCreateAndPersistsWithoutClearingSelection() throws {
        let name = "ammo-single-intent-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = MonitoringSelection(windowIDs: ["a", "b"])
        var intent = SingleActivityDisplayIntent()
        let pending = intent.begin(sessionID: "old")
        intent.stop(); SingleActivityDisplayIntentStore.save(intent, defaults: defaults)
        XCTAssertFalse(intent.permitsCreation(generation: pending, foreground: true, sourceUnchanged: true, hasSelection: true))
        XCTAssertFalse(intent.created(generation: pending))
        XCTAssertEqual(SingleActivityDisplayIntentStore.load(defaults: defaults)?.phase, .stopped)
        XCTAssertEqual(selection.windowIDs, ["a", "b"])
    }
    func testCrashDuringCreateAndSystemEndedRequireExplicitRestart() {
        var intent = SingleActivityDisplayIntent()
        _ = intent.begin(sessionID: "pending")
        intent.reconcile(runningSessionIDs: ["pending"])
        XCTAssertEqual(intent.phase, .needsRestart)
        XCTAssertFalse(intent.wantsDisplay)
        let next = intent.begin(sessionID: "next")
        XCTAssertFalse(intent.permitsCreation(generation: next, foreground: false, sourceUnchanged: true, hasSelection: true))
        XCTAssertFalse(intent.permitsCreation(generation: next, foreground: true, sourceUnchanged: false, hasSelection: true))
        XCTAssertTrue(intent.created(generation: next))
        intent.reconcile(runningSessionIDs: ["next"])
        XCTAssertEqual(intent.phase, .active)
        intent.reconcile(runningSessionIDs: [])
        XCTAssertEqual(intent.phase, .needsRestart)
    }
    func testSelectedRowsNeverGrantCreationAndNewActionInvalidatesOlderOne() {
        let selection = MonitoringSelection.restored(savedWindowIDs: ["b", "a"], runningWindowIDs: ["a", "b"])
        var intent = SingleActivityDisplayIntent()
        XCTAssertFalse(intent.wantsDisplay)
        let old = intent.begin(sessionID: "old"), current = intent.begin(sessionID: "new")
        XCTAssertFalse(intent.created(generation: old))
        XCTAssertTrue(intent.permitsCreation(generation: current, foreground: true, sourceUnchanged: true, hasSelection: !selection.windowIDs.isEmpty))
        XCTAssertTrue(intent.created(generation: current))
    }
    func testPersistedStopAfterInterruptedLegacyRemovalWinsOverRetainedSelection() throws {
        let name = "ammo-legacy-stop-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = MonitoringSelection(windowIDs: ["legacy", "second"])
        XCTAssertFalse(SingleActivityRecoveryPolicy.shouldEndLegacyActivity(savedIntent: nil, selected: true))
        var intent = SingleActivityDisplayIntent(); intent.stop()
        SingleActivityDisplayIntentStore.save(intent, defaults: defaults)
        // Recreate the launch state after interrupted local Activity removal.
        let restored = SingleActivityDisplayIntentStore.load(defaults: defaults)
        XCTAssertTrue(SingleActivityRecoveryPolicy.shouldEndLegacyActivity(savedIntent: restored, selected: true))
        XCTAssertTrue(SingleActivityRecoveryPolicy.shouldEndLegacyActivity(savedIntent: nil, selected: false))
        XCTAssertEqual(selection.windowIDs, ["legacy", "second"])
        XCTAssertEqual(restored?.phase, .stopped); XCTAssertFalse(restored!.wantsDisplay)
    }

    @MainActor
    func testFirstUpgradeMaintainsLocalAndRenewsRemoteWithoutCreatingCards() async {
        let records = [LegacyActivityMaintenanceRecord(sessionID: "local", windowID: "a", remoteUpdates: false),
                       LegacyActivityMaintenanceRecord(sessionID: "remote", windowID: "b", remoteUpdates: true)]
        var updates: [String] = [], renewals = 0
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["a", "b"],
            isCurrent: { true }, hasRecordedIntent: { false }, canRenewRemote: { true },
            updateLocal: { id, _ in updates.append(id) }, renewRemote: { _, _ in renewals += 1 }, retire: { _ in })
        XCTAssertEqual(updates, ["local"]); XCTAssertEqual(renewals, 1)
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["a", "b"],
            isCurrent: { true }, hasRecordedIntent: { true }, canRenewRemote: { true },
            updateLocal: { id, _ in updates.append(id) }, renewRemote: { _, _ in renewals += 1 }, retire: { _ in })
        XCTAssertEqual(updates, ["local"]); XCTAssertEqual(renewals, 1)
    }
    @MainActor
    func testLegacyMaintenanceRechecksStopAndSourceAfterLocalSuspension() async {
        let records = [LegacyActivityMaintenanceRecord(sessionID: "local", windowID: "a", remoteUpdates: false),
                       LegacyActivityMaintenanceRecord(sessionID: "remote", windowID: "b", remoteUpdates: true)]
        for stop in [true, false] {
            var recorded = false, current = true, renewals = 0
            await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["a", "b"],
                isCurrent: { current }, hasRecordedIntent: { recorded }, canRenewRemote: { true },
                updateLocal: { _, _ in if stop { recorded = true } else { current = false } },
                renewRemote: { _, _ in renewals += 1 }, retire: { _ in })
            XCTAssertEqual(renewals, 0)
        }
    }
    @MainActor
    func testLegacyRemoteOwnershipAndEligibilityRespectSourceAvailability() async {
        let records = [LegacyActivityMaintenanceRecord(sessionID: "remote", windowID: "a", remoteUpdates: true)]
        var localWrites = 0, renewals = 0
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["a"],
            isCurrent: { true }, hasRecordedIntent: { false }, canRenewRemote: { false },
            updateLocal: { _, _ in localWrites += 1 }, renewRemote: { _, _ in renewals += 1 }, retire: { _ in })
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: [],
            isCurrent: { true }, hasRecordedIntent: { false }, canRenewRemote: { true },
            updateLocal: { _, _ in localWrites += 1 }, renewRemote: { _, _ in renewals += 1 }, retire: { _ in })
        XCTAssertEqual(localWrites, 0); XCTAssertEqual(renewals, 0)
    }

    @MainActor
    func testMixedRemoteEligibilityRetiresMissingAAndRenewsOnlyPresentB() async {
        let records = [LegacyActivityMaintenanceRecord(sessionID: "sessionA", windowID: "a", remoteUpdates: true),
                       LegacyActivityMaintenanceRecord(sessionID: "sessionB", windowID: "b", remoteUpdates: true)]
        var renewed: [String] = [], retired: [String] = []
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["b"],
            isCurrent: { true }, hasRecordedIntent: { false }, canRenewRemote: { true },
            updateLocal: { _, _ in XCTFail("Remote cards cannot consume local values") },
            renewRemote: { id, _ in renewed.append(id) }, retire: { retired.append($0) })
        XCTAssertEqual(renewed, ["sessionB"]); XCTAssertEqual(retired, ["sessionA"])
    }
    @MainActor
    func testStopOrSourceChangeBetweenRemoteRenewalsSuppressesRemainingSession() async {
        let records = [LegacyActivityMaintenanceRecord(sessionID: "sessionA", windowID: "a", remoteUpdates: true),
                       LegacyActivityMaintenanceRecord(sessionID: "sessionB", windowID: "b", remoteUpdates: true)]
        for stop in [true, false] {
            var recorded = false, current = true, renewed: [String] = []
            await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: ["a", "b"],
                isCurrent: { current }, hasRecordedIntent: { recorded }, canRenewRemote: { true },
                updateLocal: { _, _ in XCTFail("Remote ownership") },
                renewRemote: { id, _ in renewed.append(id); if stop { recorded = true } else { current = false } },
                retire: { _ in })
            XCTAssertEqual(renewed, ["sessionA"])
        }
    }

}
