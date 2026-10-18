import Foundation
import XCTest
import QuotaCore
@testable import QuotaPhone

private let resetNow = Date(timeIntervalSince1970: 1_791_374_400)
private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func resetSnapshot(count: Int = 1, epoch: String = "epoch-a", sequence: Int64 = 1,
                           reset: String? = nil, observed: Date = resetNow, stale: Date = resetNow.addingTimeInterval(300),
                           outcome: String = "ok", quality: String = "reported", availability: String = "available",
                           quotaKey: String = "five-hour", account: String? = nil) throws -> Snapshot {
    let windows: [[String: Any]] = (0..<count).map { index in
        ["id": "window-\(index)", "providerId": "codex", "accountId": account ?? "account-\(index)",
         "accountAlias": "Same alias", "quotaKey": quotaKey, "sharedPoolId": NSNull(),
         "unit": "percent", "currency": NSNull(), "availability": availability,
         "remainingBps": 8000, "amount": NSNull(), "limit": NSNull(), "quality": quality,
         "sourceMethod": "official_api", "fetchOutcome": outcome, "observedAt": stamp(observed), "staleAt": stamp(stale),
         "window": ["kind": "rolling", "durationSeconds": 18000, "startsAt": NSNull(),
                    "resetsAt": reset ?? stamp(resetNow.addingTimeInterval(7200 + Double(index))), "periodId": NSNull()], "history": []]
    }
    let object: [String: Any] = ["schemaVersion": "1", "snapshotId": "snapshot-\(sequence)",
        "sourceDeviceId": "synthetic-mac", "sourceEpoch": epoch, "sourceSequence": sequence,
        "capturedAt": stamp(resetNow), "windows": windows]
    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor
private final class ReminderClock { var now = resetNow }

@MainActor
private final class ReminderMemory: ResetReminderStorage {
    var data: Data?
    var fails = false
    var writes = 0
    var failAtWrite: Int?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        writes += 1
        if fails || writes == failAtWrite { throw CocoaError(.fileWriteNoPermission) }
        self.data = data
    }
}
@MainActor
private final class ReminderClient: ResetReminderNotificationClient {
    var pending: [String: ResetReminderRequest] = [:]
    var unrelated = Set(["billing-other", "other-app-feature"])
    var additions: [String] = []
    var removed: [String] = []
    var authorized = true
    var pauseAuthorization = false
    var pauseReadAuthorization = false
    var authContinuation: CheckedContinuation<Bool, Never>?
    var pauseAdd = false
    var rejectAdd = false
    var pauseAddAt: Int?
    var pausePending = false
    var pausePendingAt: Int?
    var pendingReads = 0
    var deferRemoval = false
    var deferredRemoval = Set<String>()
    var capturedPending = Set<String>()
    var pendingContinuation: CheckedContinuation<Set<String>, Never>?
    var addContinuation: CheckedContinuation<Void, Never>?
    func authorize(requestIfNeeded: Bool) async throws -> Bool {
        if (requestIfNeeded && pauseAuthorization) || (!requestIfNeeded && pauseReadAuthorization) {
            pauseReadAuthorization = false
            return await withCheckedContinuation { authContinuation = $0 }
        }
        return authorized
    }
    func pendingIDs() async -> Set<String> {
        pendingReads += 1
        if pausePending || pendingReads == pausePendingAt {
            pausePending = false
            return await withCheckedContinuation { pendingContinuation = $0 }
        }
        return Set(pending.keys).union(unrelated)
    }
    func startPendingQuery() -> Task<Set<String>, Never> {
        pendingReads += 1
        let snapshot = Set(pending.keys).union(unrelated)
        capturedPending = snapshot
        if pausePending || pendingReads == pausePendingAt {
            pausePending = false
            return Task { await withCheckedContinuation { pendingContinuation = $0 } }
        }
        return Task { snapshot }
    }
    func add(_ request: ResetReminderRequest) async throws {
        if rejectAdd {
            if pauseAdd {
                pauseAdd = false
                await withCheckedContinuation { addContinuation = $0 }
            }
            throw CocoaError(.featureUnsupported)
        }
        pending[request.id] = request; additions.append(request.id)
        if pauseAdd || additions.count == pauseAddAt {
            pauseAdd = false
            await withCheckedContinuation { addContinuation = $0 }
        }
    }
    func remove(ids: [String]) {
        removed += ids
        if deferRemoval { deferredRemoval.formUnion(ids); return }
        for id in ids { pending.removeValue(forKey: id); unrelated.remove(id) }
    }
    func finishRemoval() {
        for id in deferredRemoval { pending.removeValue(forKey: id); unrelated.remove(id) }
        deferredRemoval.removeAll()
    }
}

final class ResetReminderPolicyTests: XCTestCase {
    func testDefaultsFreshnessManualResetCreditsAndMissingFireTime() throws {
        XCTAssertEqual(ResetReminderSettings(), ResetReminderSettings(enabled: false, leadMinutes: 15))
        let on = ResetReminderSettings(enabled: true)
        XCTAssertEqual(ResetReminderPolicy.requests(snapshot: try resetSnapshot(), settings: on, now: resetNow).count, 1)
        for input in [try resetSnapshot(outcome: "auth_required"), try resetSnapshot(outcome: "error"),
                      try resetSnapshot(quality: "estimated"), try resetSnapshot(availability: "unavailable"),
                      try resetSnapshot(stale: resetNow), try resetSnapshot(observed: resetNow.addingTimeInterval(121)),
                      try resetSnapshot(quotaKey: "rate-limit-reset-credits"),
                      try resetSnapshot(quotaKey: "cost-spend"),
                      try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(600)))] {
            XCTAssertTrue(ResetReminderPolicy.requests(snapshot: input, settings: on, now: resetNow).isEmpty)
        }
        XCTAssertTrue(ResetReminderPolicy.requests(snapshot: try resetSnapshot(), settings: on, now: resetNow, clockOffset: 121).isEmpty)
    }
    func testCanonicalUTCIdentityDSTAndMultipleAccounts() throws {
        let on = ResetReminderSettings(enabled: true)
        let a = try resetSnapshot(reset: "2026-10-08T01:00:00Z")
        let b = try resetSnapshot(reset: "2026-10-07T18:00:00-07:00")
        XCTAssertEqual(ResetReminderPolicy.requests(snapshot: a, settings: on, now: resetNow).first?.id,
                       ResetReminderPolicy.requests(snapshot: b, settings: on, now: resetNow).first?.id)
        let inputs = try resetSnapshot(count: 2)
        let requests = ResetReminderPolicy.requests(snapshot: inputs, settings: on, now: resetNow)
        XCTAssertEqual(Set(requests.map(\.id)).count, 2)
        XCTAssertFalse(requests[0].id.contains("account"))
        XCTAssertNotEqual(requests[0].accountKey, requests[1].accountKey)
        let dstInstant = try XCTUnwrap(QuotaRules.date("2026-11-01T06:30:00Z"))
        let components = ResetReminderPolicy.utcComponents(for: dstInstant)
        XCTAssertEqual(components.timeZone?.secondsFromGMT(for: dstInstant), 0)
        XCTAssertEqual(components.calendar?.date(from: components), dstInstant)
        XCTAssertEqual(components.hour, 6)
        let changed = ResetReminderPolicy.requests(snapshot: a, settings: ResetReminderSettings(enabled: true, leadMinutes: 30), now: resetNow)
        let original = ResetReminderPolicy.requests(snapshot: a, settings: on, now: resetNow)
        XCTAssertEqual(changed.first?.cycleID, original.first?.cycleID)
        XCTAssertNotEqual(changed.first?.id, original.first?.id)
    }
}

@MainActor
final class ResetReminderCoordinatorTests: XCTestCase {
    private func configured(_ client: ReminderClient, storage: ReminderMemory = ReminderMemory()) async -> ResetReminderCoordinator {
        let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        await coordinator.setEnabled(true, now: resetNow)
        return coordinator
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Suspension point was not reached")
        throw CocoaError(.featureUnsupported)
    }
    func testOfflineRetainsForecastAuthoritativeRemovalCancelsAndPrefixIsScoped() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        let first = Set(client.pending.keys)
        await coordinator.reconcile(snapshot: nil, verified: false, now: resetNow)
        XCTAssertEqual(Set(client.pending.keys), first)
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 2, outcome: "error"), verified: true, now: resetNow)
        XCTAssertEqual(Set(client.pending.keys), first)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 3), verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }
    func testRestartSuppressesDeliveredCycleAndChangedLeadReplacesPendingOnly() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        let snapshot = try resetSnapshot()
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        let first = try XCTUnwrap(client.pending.keys.first)
        await coordinator.setLeadMinutes(30, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertNil(client.pending[first])
        XCTAssertEqual(client.additions.count, 2)
        client.pending.removeAll() // OS delivered it while the app was not running.
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        await restarted.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        await restarted.setLeadMinutes(60, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 2)
        await restarted.setEnabled(false, now: resetNow)
        await restarted.setEnabled(true, now: resetNow)
        XCTAssertEqual(client.additions.count, 2)
    }
    func testLateAuthorizationCannotReenableAfterDisable() async throws {
        let client = ReminderClient(); client.pauseAuthorization = true
        let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { resetNow })
        let enabling = Task { await coordinator.setEnabled(true, now: resetNow) }
        try await waitUntil { client.authContinuation != nil }
        await coordinator.setEnabled(false, now: resetNow)
        client.authContinuation?.resume(returning: true); client.authContinuation = nil
        await enabling.value
        XCTAssertFalse(coordinator.settings.enabled)
        XCTAssertTrue(client.pending.isEmpty)
    }
    func testLateAcceptedAddCannotSurviveDisableOrEpochReplacement() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        client.pauseAdd = true
        let old = try resetSnapshot()
        let adding = Task { await coordinator.reconcile(snapshot: old, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        let disabling = Task { await coordinator.setEnabled(false, now: resetNow) }
        try await waitUntil { !coordinator.settings.enabled }
        XCTAssertTrue(client.pending.isEmpty, "Disable removes the accepted prepared ID before add resumes")
        client.addContinuation?.resume(); client.addContinuation = nil
        await adding.value; await disabling.value
        XCTAssertTrue(client.pending.isEmpty)
        await coordinator.setEnabled(true, now: resetNow)
        client.pauseAdd = true
        let newOld = try resetSnapshot(sequence: 2, reset: stamp(resetNow.addingTimeInterval(8000)))
        let second = Task { await coordinator.reconcile(snapshot: newOld, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        coordinator.invalidateSource(now: resetNow)
        XCTAssertTrue(client.pending.isEmpty, "Source invalidation removes prepared IDs synchronously")
        let replacement = try resetSnapshot(epoch: "epoch-b", sequence: 1)
        let replacing = Task { await coordinator.reconcile(snapshot: replacement, verified: true, now: resetNow) }
        client.addContinuation?.resume(); client.addContinuation = nil
        await second.value; await replacing.value
        XCTAssertEqual(Set(client.pending.keys), Set(ResetReminderPolicy.requests(snapshot: replacement, settings: coordinator.settings, now: resetNow).map(\.id)))
    }
    func testPreparedRecordRecoversAcceptanceWithoutDuplicateAdd() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        client.pauseAdd = true
        let snapshot = try resetSnapshot()
        let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        let crashStorage = ReminderMemory(); crashStorage.data = storage.data
        client.addContinuation?.resume(); client.addContinuation = nil; await adding.value
        let restarted = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { resetNow })
        await restarted.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 1)
        client.pending.removeAll()
        let again = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { resetNow })
        await again.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 1)
    }
    func testPreparedDeliveryWhileClosedSurvivesRestartAndShorterLead() async throws {
        for legacyLedger in [false, true] {
            for disableBeforeReconcile in [false, true] {
                let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
                let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
                await coordinator.setEnabled(true, now: resetNow)
                await coordinator.setLeadMinutes(60, now: resetNow)
                let snapshot = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)))
                client.pauseAdd = true
                let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
                try await waitUntil { client.addContinuation != nil }
                let crashStorage = ReminderMemory(); crashStorage.data = storage.data
                if legacyLedger {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(crashStorage.data)) as? [String: Any])
                    object["issuedCycles"] = [String: Any]() // Older preparation did not persist a marker.
                    crashStorage.data = try JSONSerialization.data(withJSONObject: object)
                }
                client.addContinuation?.resume(); await adding.value
                time.now = resetNow.addingTimeInterval(90)
                client.pending.removeAll() // Accepted request fired while the app was closed.
                let restarted = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { time.now })
                if disableBeforeReconcile { await restarted.setEnabled(false, now: time.now) }
                else { await restarted.reconcile(snapshot: snapshot, verified: true, now: time.now) }
                await restarted.setLeadMinutes(5, now: time.now)
                if disableBeforeReconcile { await restarted.setEnabled(true, now: time.now) }
                await restarted.reconcile(snapshot: snapshot, verified: true, now: time.now)
                XCTAssertTrue(client.pending.isEmpty)
                XCTAssertEqual(client.additions.count, 1, "Unresolved elapsed preparation must not repeat the delivered cycle")
                let again = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { time.now })
                await again.reconcile(snapshot: snapshot, verified: true, now: time.now)
                XCTAssertEqual(client.additions.count, 1, "Recovery suppression survives another restart")
            }
        }
    }

    func testPreparedCancellationRearmsOnlyWithConfirmedFuturePendingEvidence() async throws {
        for confirmedPending in [false, true] {
            let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
            let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await coordinator.setEnabled(true, now: resetNow)
            await coordinator.setLeadMinutes(60, now: resetNow)
            let snapshot = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)))
            client.pauseAdd = true
            let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
            try await waitUntil { client.addContinuation != nil }
            let crashStorage = ReminderMemory(); crashStorage.data = storage.data
            client.addContinuation?.resume(); await adding.value
            if !confirmedPending { client.pending.removeAll() } // Missing evidence, not proof of rejection.
            let restarted = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { time.now })
            await restarted.setEnabled(false, now: resetNow)
            XCTAssertTrue(client.pending.isEmpty)
            time.now = resetNow.addingTimeInterval(90)
            await restarted.setLeadMinutes(5, now: time.now)
            await restarted.setEnabled(true, now: time.now)
            await restarted.reconcile(snapshot: snapshot, verified: true, now: time.now)
            XCTAssertEqual(client.additions.count, confirmedPending ? 2 : 1)
            XCTAssertEqual(client.pending.count, confirmedPending ? 1 : 0)
        }
    }

    func testExplicitAddRejectionDoesNotSuppressLaterValidLead() async throws {
        let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
        let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
        await coordinator.setEnabled(true, now: resetNow)
        await coordinator.setLeadMinutes(60, now: resetNow)
        let snapshot = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)))
        client.rejectAdd = true; client.pauseAdd = true
        let rejecting = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        time.now = resetNow.addingTimeInterval(90)
        client.addContinuation?.resume(); await rejecting.value
        XCTAssertTrue(client.pending.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
        XCTAssertEqual((object["issuedCycles"] as? [String: Any])?.count, 0)
        client.rejectAdd = false; time.now = resetNow.addingTimeInterval(90)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
        await restarted.setLeadMinutes(5, now: time.now)
        await restarted.reconcile(snapshot: snapshot, verified: true, now: time.now)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 1)
    }

    func testAccountPauseClockSkewStaleSnapshotsAndCap() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        let snapshot = try resetSnapshot(count: 80, sequence: 10)
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 48)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 9), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 48)
        coordinator.updateAllowedAccounts([ResetReminderPolicy.accountKey(providerID: "codex", accountID: "account-1")])
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 11), verified: true, now: resetNow, clockOffset: 121)
        XCTAssertTrue(client.pending.isEmpty)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 12), verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
    }
    func testFreshRefreshDuringPermissionDoesNotLoseOptInButNewSourceDoes() async throws {
        let client = ReminderClient(); client.pauseAuthorization = true
        let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { resetNow })
        let enabling = Task { await coordinator.setEnabled(true, now: resetNow) }
        try await waitUntil { client.authContinuation != nil }
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        client.authContinuation?.resume(returning: true); client.authContinuation = nil
        await enabling.value
        XCTAssertTrue(coordinator.settings.enabled)
        XCTAssertEqual(client.pending.count, 1)
        await coordinator.setEnabled(false, now: resetNow)
        let again = Task { await coordinator.setEnabled(true, now: resetNow) }
        try await waitUntil { client.authContinuation != nil }
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "replacement"), verified: true, now: resetNow)
        client.authContinuation?.resume(returning: true); client.authContinuation = nil
        await again.value
        XCTAssertFalse(coordinator.settings.enabled)
        XCTAssertTrue(client.pending.isEmpty)
    }
    func testOfflineLeadChangeWaitsForFreshObservationAndResetChangeReplaces() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        let old = try XCTUnwrap(client.pending.keys.first)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: false, now: resetNow)
        await coordinator.setLeadMinutes(30, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 1)
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 2), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertNil(client.pending[old])
        let beforeResetChange = try XCTUnwrap(client.pending.keys.first)
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 3, reset: stamp(resetNow.addingTimeInterval(9000))), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertNil(client.pending[beforeResetChange])
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 4, outcome: "auth_required"), verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
    }
    func testNewEpochCancelsOldForecastEvenWhenClockIsUntrusted() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "new-epoch"), verified: true, now: resetNow, clockOffset: 180)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 1)
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "new-epoch", sequence: 2), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 2)
    }
    func testLedgerContainsHashesAndTimesWithoutSnapshotAliasesOrSourceIDs() async throws {
        let storage = ReminderMemory(); let client = ReminderClient(); let coordinator = await configured(client, storage: storage)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        let ledger = try XCTUnwrap(storage.data.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(ledger.contains("Same alias"))
        XCTAssertFalse(ledger.contains("synthetic-mac"))
        XCTAssertFalse(ledger.contains("account-0"))
        XCTAssertFalse(ledger.contains("epoch-a"))
    }
    func testCachedDifferentOwnerCancelsOldForecastWithoutScheduling() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "cached-new-owner"), verified: false, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 1)
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "cached-new-owner", sequence: 2, observed: resetNow.addingTimeInterval(-60)), verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty) // Accepted cached observation also sets the high-water.
        XCTAssertEqual(client.additions.count, 1)
    }
    func testOlderWindowObservationAndSequenceRollbackCannotReplaceLatestForecast() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 10), verified: true, now: resetNow)
        let original = Set(client.pending.keys)
        await coordinator.reconcile(snapshot: try resetSnapshot(sequence: 11, reset: stamp(resetNow.addingTimeInterval(6000)), observed: resetNow.addingTimeInterval(-60)), verified: true, now: resetNow)
        XCTAssertEqual(Set(client.pending.keys), original)
        XCTAssertEqual(client.additions.count, 1)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        await restarted.reconcile(snapshot: try resetSnapshot(sequence: 12, reset: stamp(resetNow.addingTimeInterval(5000)), observed: resetNow.addingTimeInterval(-90)), verified: true, now: resetNow)
        XCTAssertEqual(Set(client.pending.keys), original)
        await restarted.reconcile(snapshot: try resetSnapshot(sequence: 13), verified: true, now: resetNow)
        await restarted.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 9), verified: true, now: resetNow)
        await restarted.setLeadMinutes(30, now: resetNow)
        XCTAssertEqual(client.pending.count, 1) // Intake kept the latest 13, not rejected 9.
    }
    func testDisablePauseAndSameSourceReconnectRearmOnlyCancelledFutureCycles() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        let snapshot = try resetSnapshot()
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        await coordinator.setEnabled(false, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        await coordinator.setEnabled(true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 2)
        coordinator.updateAllowedAccounts([])
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        coordinator.updateAllowedAccounts(nil)
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 3)
        await coordinator.cancelAll(now: resetNow)
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 4)
        client.pending.removeAll() // Delivered cycles are still suppressed.
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        await coordinator.setEnabled(false, now: resetNow)
        await coordinator.setEnabled(true, now: resetNow)
        XCTAssertEqual(client.additions.count, 4)
    }
    func testUnrelatedPendingOccupancyLimitsReminderSlotsAndStatus() async throws {
        let client = ReminderClient(); client.unrelated = Set((0..<60).map { "billing-\($0)" })
        let coordinator = await configured(client)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 10), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 4)
        XCTAssertEqual(client.unrelated.count, 60)
        XCTAssertEqual(coordinator.status.key, "resetReminder.capped")
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 10, sequence: 2, outcome: "error"), verified: true, now: resetNow)
        client.unrelated.insert("billing-60")
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 10, sequence: 3, outcome: "error"), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 3)
        XCTAssertEqual(client.unrelated.count, 61)
        XCTAssertEqual(coordinator.status.key, "resetReminder.capped")
    }
    func testActiveHistoryCapPreservesSuppressionAndExpiredCyclesMakeRoom() async throws {
        func ledger(expired: Bool) throws -> Data {
            let date = resetNow.addingTimeInterval(expired ? -1 : 10_000).timeIntervalSinceReferenceDate
            let cycles = Dictionary(uniqueKeysWithValues: (0..<2048).map { ("hash-\($0)", date) })
            return try JSONSerialization.data(withJSONObject: [
                "settings": ["enabled": true, "leadMinutes": 15], "scope": ResetReminderPolicy.scope(try resetSnapshot()),
                "sequence": 1, "records": [:], "issuedCycles": cycles, "windowObservations": [:]
            ])
        }
        let full = ReminderMemory(); full.data = try ledger(expired: false)
        let client = ReminderClient(); let coordinator = ResetReminderCoordinator(storage: full, client: client, clock: { resetNow })
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        XCTAssertTrue(coordinator.settings.enabled)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(coordinator.status.key, "resetReminder.capped")
        let saved = try XCTUnwrap(full.data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual((object["issuedCycles"] as? [String: Any])?.count, 2048)
        await coordinator.reconcile(snapshot: try resetSnapshot(epoch: "epoch-b"), verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty, "Changing source cannot discard active suppression to make capacity")
        XCTAssertEqual(coordinator.status.key, "resetReminder.capped")
        let restarted = ResetReminderCoordinator(storage: full, client: client, clock: { resetNow })
        XCTAssertTrue(restarted.settings.enabled)
        XCTAssertNotEqual(restarted.status.key, "resetReminder.storageError")
        let old = ReminderMemory(); old.data = try ledger(expired: true)
        let pruned = ResetReminderCoordinator(storage: old, client: client, clock: { resetNow })
        await pruned.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        let oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(old.data)) as? [String: Any])
        XCTAssertEqual((oldObject["issuedCycles"] as? [String: Any])?.count, 1)
    }
    func testPermissionRevocationCancelsAndPermissionRecoveryRearmsFutureForecast() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        let snapshot = try resetSnapshot()
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        client.authorized = false
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(coordinator.status.key, "resetReminder.denied")
        client.authorized = true
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.additions.count, 2)
    }
    func testRuntimeGuardExcludesFixturesUnbundledAndHostedTests() async throws {
        func allowed(_ bundle: String = "app", _ id: String? = "com.synthetic.ammo", args: [String] = [], env: [String: String] = [:], testRuntime: Bool = false) -> Bool {
            ResetReminderRuntime.allowsPersistentEffects(bundleExtension: bundle, bundleIdentifier: id, arguments: args, environment: env, testingRuntime: testRuntime)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed("xctest"))
        XCTAssertFalse(allowed("", nil))
        XCTAssertFalse(allowed(args: ["Ammo", "--fixture", "synthetic.json"]))
        XCTAssertFalse(allowed(env: ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]))
        XCTAssertFalse(allowed(env: ["XCTestBundlePath": "/synthetic/Test.xctest"]))
        XCTAssertFalse(allowed(env: ["SWIFT_TESTING_ENABLED": "1"]))
        XCTAssertFalse(allowed(testRuntime: true))
        XCTAssertFalse(ResetReminderRuntime.isNativeApplication)
        let local = ResetReminderCoordinator.local()
        await local.setEnabled(true, now: resetNow)
        XCTAssertFalse(local.settings.enabled) // System client never prompts in XCTest.
    }
    func testStorageFailureDuringBatchOrOfflineCancelsEveryOwnedForecast() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        storage.failAtWrite = storage.writes + 4 // Second prepare, after the first OS acceptance.
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 2), verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 1)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertFalse(coordinator.settings.enabled)
        XCTAssertEqual(coordinator.status.key, "resetReminder.storageError")
        let nextStorage = ReminderMemory(); let next = await configured(client, storage: nextStorage)
        await next.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        nextStorage.fails = true
        await next.reconcile(snapshot: nil, verified: false, now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertFalse(next.settings.enabled)
        XCTAssertEqual(next.status.key, "resetReminder.storageError")
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }
    func testSubsetCancellationStorageFailureRequestsCleanupOfEntireOwnedBatch() async throws {
        for deferredRemoval in [false, true] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            let original = try resetSnapshot(count: 2)
            await coordinator.reconcile(snapshot: original, verified: true, now: resetNow)
            let oldIDs = Set(client.pending.keys)
            XCTAssertEqual(oldIDs.count, 2)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
                resetSnapshot(count: 2, sequence: 2))) as? [String: Any])
            var windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
            var timing = try XCTUnwrap(windows[0]["window"] as? [String: Any])
            timing["resetsAt"] = stamp(resetNow.addingTimeInterval(9000))
            windows[0]["window"] = timing; object["windows"] = windows
            let changed = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let ledgerBeforeFailure = storage.data
            client.removed.removeAll(); client.deferRemoval = deferredRemoval
            storage.failAtWrite = storage.writes + 1 // Only the first obsolete-record cancellation write fails.
            await coordinator.reconcile(snapshot: changed, verified: true, now: resetNow)
            XCTAssertFalse(coordinator.settings.enabled)
            XCTAssertEqual(coordinator.status.key, "resetReminder.storageError")
            XCTAssertTrue(oldIDs.isSubset(of: Set(client.removed)), "Failure cleanup includes the unaffected window, not only the obsolete subset")
            XCTAssertEqual(client.additions.count, 2)
            XCTAssertEqual(storage.data, ledgerBeforeFailure, "Failed persistence leaves durable cycle suppression intact")
            if deferredRemoval {
                XCTAssertTrue(oldIDs.isSubset(of: client.deferredRemoval), "Native asynchronous cleanup is requested for every known ID")
                client.finishRemoval(); client.deferRemoval = false
            }
            XCTAssertTrue(client.pending.isEmpty)
            await coordinator.setEnabled(true, now: resetNow)
            XCTAssertFalse(coordinator.settings.enabled)
            XCTAssertEqual(client.additions.count, 2, "An unreadable coordinator cannot add further reminders")
            XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
        }
    }
    func testFileLedgerUsesPrivatePermissionsAndRejectsUnsafeRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reset-ledger-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let storage = FileResetReminderStorage(url: url)
        XCTAssertNil(try storage.read())
        try storage.write(Data("synthetic".utf8))
        XCTAssertEqual(try storage.read(), Data("synthetic".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try storage.read())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertThrowsError(try storage.read())
    }
    func testAcceptedAndPreparedRequestsDisappearBeforeWaitsAndRapidEnableCannotBypassBarrier() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        client.pauseAddAt = 2
        let snapshot = try resetSnapshot(count: 2)
        let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        XCTAssertEqual(client.pending.count, 2)
        client.pausePending = true
        let disabling = Task { await coordinator.setEnabled(false, now: resetNow) }
        try await waitUntil { client.pendingContinuation != nil }
        XCTAssertTrue(client.pending.isEmpty, "Both accepted and prepared IDs disappear while add and query remain suspended")
        let enabling = Task { await coordinator.setEnabled(true, now: resetNow) }
        try await waitUntil { coordinator.settings.enabled }
        client.addContinuation?.resume(); client.addContinuation = nil
        await adding.value
        XCTAssertTrue(client.pending.isEmpty, "Re-enable must wait for cancellation's pending query/barrier")
        XCTAssertEqual(client.additions.count, 2)
        client.pendingContinuation?.resume(returning: client.capturedPending); client.pendingContinuation = nil
        await disabling.value; await enabling.value
        XCTAssertEqual(client.pending.count, 2)
        XCTAssertEqual(client.additions.count, 4)
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }
    func testSourceInvalidationImmediatelyRemovesAcceptedAndPreparedBatch() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        client.pauseAddAt = 2
        let snapshot = try resetSnapshot(count: 2)
        let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        coordinator.invalidateSource(now: resetNow)
        XCTAssertTrue(client.pending.isEmpty)
        let replacing = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        client.addContinuation?.resume(); client.addContinuation = nil
        await adding.value; await replacing.value
        XCTAssertEqual(client.pending.count, 2)
        XCTAssertEqual(client.additions.count, 4)
    }
    func testAcceptedDifferentOwnerAndWindowRevocationRemoveIDsBeforeOldAddCompletes() async throws {
        for differentOwner in [false, true] {
            let client = ReminderClient(); let coordinator = await configured(client)
            client.pauseAddAt = 2
            let snapshot = try resetSnapshot(count: 2)
            let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
            try await waitUntil { client.addContinuation != nil }
            let replacement = try resetSnapshot(count: differentOwner ? 2 : 0, epoch: differentOwner ? "cached-new-owner" : "epoch-a", sequence: 2)
            let reconciling = Task { await coordinator.reconcile(snapshot: replacement, verified: !differentOwner, now: resetNow, clockOffset: 181) }
            try await waitUntil { client.pending.isEmpty }
            XCTAssertEqual(client.additions.count, 2)
            client.addContinuation?.resume(); client.addContinuation = nil
            await adding.value; await reconciling.value
            XCTAssertTrue(client.pending.isEmpty)
        }
    }
    func testAuthorizationWaitRechecksExpiryAndBackwardClock() async throws {
        for shift: TimeInterval in [301, -181] {
            let time = ReminderClock(); let client = ReminderClient(); client.pauseAuthorization = true
            let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { time.now })
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
            let enabling = Task { await coordinator.setEnabled(true, now: resetNow) }
            try await waitUntil { client.authContinuation != nil }
            time.now = resetNow.addingTimeInterval(shift)
            client.authContinuation?.resume(returning: true); client.authContinuation = nil
            await enabling.value
            XCTAssertTrue(client.pending.isEmpty, "Expired or >120s future observations cannot schedule after permission resumes")
        }
    }
    func testDelayedBatchRechecksEveryNextAddForExpiryAndElapsedTrigger() async throws {
        for elapsed: TimeInterval in [301, 7000] {
            let time = ReminderClock(); let client = ReminderClient()
            let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { time.now })
            await coordinator.setEnabled(true, now: resetNow)
            client.pauseAdd = true
            let snapshot = try resetSnapshot(count: 2, stale: resetNow.addingTimeInterval(elapsed == 301 ? 300 : 9000))
            let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
            try await waitUntil { client.addContinuation != nil }
            time.now = resetNow.addingTimeInterval(elapsed)
            client.addContinuation?.resume(); client.addContinuation = nil
            await adding.value
            XCTAssertEqual(client.additions.count, 1, "The second forecast must be rechecked after the first add suspends")
        }
    }
    func testAuthoritativeRevocationsCancelWithClockSkew() async throws {
        for outcome in ["auth_required", "disabled", "unavailable", "missing"] {
            let client = ReminderClient(); let coordinator = await configured(client)
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
            let revoked = try resetSnapshot(count: outcome == "missing" ? 0 : 1, sequence: 2,
                outcome: outcome == "auth_required" || outcome == "disabled" ? outcome : "ok",
                availability: outcome == "unavailable" ? "unavailable" : "available")
            await coordinator.reconcile(snapshot: revoked, verified: true, now: resetNow, clockOffset: 181)
            XCTAssertTrue(client.pending.isEmpty, outcome)
        }
    }
    func testCFRestartProvenanceCancelsRevokedForecastWithoutDisplayedSnapshot() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: .cloudflare)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        await restarted.reconcile(snapshot: nil, verified: false, now: resetNow)
        XCTAssertEqual(restarted.source, .cloudflare)
        let revoked = PhoneResetReminderSourcePolicy.shouldCancel(source: restarted.source, cfRevoked: true,
            iCloudRevoked: false, cfEnabled: true, iCloudEnabled: false)
        XCTAssertTrue(revoked)
        if revoked { await restarted.cancelAll(now: resetNow) }
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertTrue(PhoneResetReminderSourcePolicy.shouldCancel(source: nil, cfRevoked: true,
            iCloudRevoked: false, cfEnabled: true, iCloudEnabled: false))
        XCTAssertFalse(PhoneResetReminderSourcePolicy.shouldCancel(source: .iCloud, cfRevoked: true,
            iCloudRevoked: false, cfEnabled: true, iCloudEnabled: true))
    }
    func testRefreshIdentityRejectsOldClientAndOldTransitionCannotUnlockNewOwner() throws {
        let oldClient = NSObject(); let newClient = NSObject(); let generation = UUID()
        let old = PhoneRefreshIdentity(generation: generation, credentialScope: "old", clientIdentifier: ObjectIdentifier(oldClient))
        let new = PhoneRefreshIdentity(generation: generation, credentialScope: "new", clientIdentifier: ObjectIdentifier(newClient))
        XCTAssertFalse(old.accepts(current: new, transitioning: false))
        let sameScopeNewClient = PhoneRefreshIdentity(generation: generation, credentialScope: "old", clientIdentifier: ObjectIdentifier(newClient))
        XCTAssertFalse(old.accepts(current: sameScopeNewClient, transitioning: false))
        var transition = PhoneCredentialTransition()
        let first = try XCTUnwrap(transition.begin())
        XCTAssertNil(transition.begin())
        XCTAssertFalse(new.accepts(current: new, transitioning: transition.isTransitioning))
        transition.finish(first)
        let second = try XCTUnwrap(transition.begin())
        transition.finish(first) // A completed rotation's defer executes after another rotation starts.
        XCTAssertTrue(transition.isTransitioning)
        transition.finish(second)
        XCTAssertTrue(new.accepts(current: new, transitioning: transition.isTransitioning))
    }
    func testAccountPauseImmediatelyRemovesBothBatchRequestsAndRetainsBarrier() async throws {
        let client = ReminderClient(); let coordinator = await configured(client)
        client.pauseAddAt = 2
        let snapshot = try resetSnapshot(count: 2)
        let adding = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        client.pausePending = true
        coordinator.updateAllowedAccounts([])
        XCTAssertTrue(client.pending.isEmpty, "Disallowed accepted/prepared account requests disappear synchronously")
        try await waitUntil { client.pendingContinuation != nil }
        let beforeRemoval = client.capturedPending
        coordinator.updateAllowedAccounts(nil)
        let resuming = Task { await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow) }
        client.addContinuation?.resume(); client.addContinuation = nil
        await adding.value
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 2)
        client.pendingContinuation?.resume(returning: beforeRemoval); client.pendingContinuation = nil
        await resuming.value
        XCTAssertEqual(client.pending.count, 2)
        XCTAssertEqual(client.additions.count, 4)
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }
    func testRestartDisableBeforeReconciliationRearmsOnlyConfirmedPendingForecast() async throws {
        for delivered in [false, true] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            let snapshot = try resetSnapshot()
            await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
            if delivered { client.pending.removeAll() }
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
            client.pausePending = true
            let disabling = Task { await restarted.setEnabled(false, now: resetNow) }
            try await waitUntil { client.pendingContinuation != nil }
            XCTAssertTrue(client.pending.isEmpty, "Immediate removal never waits for proof-query completion")
            let pendingEvidence = client.capturedPending
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
            XCTAssertEqual((object["cancelledRecords"] as? [String: Any])?.count, 1, "Cancellation bookkeeping persists until proof arrives")
            client.pendingContinuation?.resume(returning: pendingEvidence); client.pendingContinuation = nil
            await disabling.value
            await restarted.setEnabled(true, now: resetNow)
            await restarted.reconcile(snapshot: snapshot, verified: true, now: resetNow)
            XCTAssertEqual(client.pending.count, delivered ? 0 : 1)
            XCTAssertEqual(client.additions.count, delivered ? 1 : 2)
        }
    }
    func testMissingCancellationProofDoesNotReleaseDeliveredMarker() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        let snapshot = try resetSnapshot()
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        client.pausePending = true
        let disabling = Task { await restarted.setEnabled(false, now: resetNow) }
        try await waitUntil { client.pendingContinuation != nil }
        XCTAssertTrue(client.pending.isEmpty)
        client.pendingContinuation?.resume(returning: client.unrelated) // OS callback may observe post-removal state.
        client.pendingContinuation = nil
        await disabling.value
        await restarted.setEnabled(true, now: resetNow)
        await restarted.reconcile(snapshot: snapshot, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 1, "Unknown or missing OS evidence keeps cycle suppression conservative")
    }
    func testTransportDisableUsesPersistedOwnerWhenDisplayIsMissingAndOtherTransportFails() async throws {
        for source in [ResetReminderSource.cloudflare, .iCloud] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: source)
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
            await restarted.reconcile(snapshot: nil, verified: false, now: resetNow)
            XCTAssertEqual(client.pending.count, 1)
            let cancel = PhoneResetReminderSourcePolicy.shouldCancel(source: restarted.source, cfRevoked: false, iCloudRevoked: false,
                cfEnabled: source != .cloudflare, iCloudEnabled: source != .iCloud)
            XCTAssertTrue(cancel)
            if cancel { restarted.invalidateSource(now: resetNow) }
            XCTAssertTrue(client.pending.isEmpty)
            await restarted.reconcile(snapshot: nil, verified: false, now: resetNow) // Other enabled transport failed.
            XCTAssertTrue(client.pending.isEmpty)
            XCTAssertFalse(PhoneResetReminderSourcePolicy.shouldCancel(source: source, cfRevoked: false, iCloudRevoked: false,
                cfEnabled: source == .cloudflare, iCloudEnabled: source == .iCloud), "Disabling the non-owner must preserve this source")
        }
    }
    func testDisabledCachedICloudRevocationCannotScheduleBeforeReplacementRefreshCompletes() async throws {
        let client = ReminderClient()
        let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { resetNow })
        await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: .iCloud)
        XCTAssertFalse(coordinator.settings.enabled)
        XCTAssertNil(coordinator.source)
        XCTAssertEqual(coordinator.eligibilitySource, .iCloud)
        let cancel = PhoneResetReminderSourcePolicy.shouldCancel(source: coordinator.source,
            eligibilitySource: coordinator.eligibilitySource, cfRevoked: false, iCloudRevoked: true,
            cfEnabled: true, iCloudEnabled: true)
        XCTAssertTrue(cancel)
        if cancel { coordinator.invalidateSource(now: resetNow) }

        // The host starts a replacement refresh after CKAccountChanged. Its
        // result is unavailable while the user enables reminders.
        var refreshContinuation: CheckedContinuation<Snapshot?, Never>?
        let refresh = Task { @MainActor in
            let snapshot = await withCheckedContinuation { refreshContinuation = $0 }
            await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .iCloud)
        }
        try await waitUntil { refreshContinuation != nil }
        await coordinator.setEnabled(true, now: resetNow)
        XCTAssertTrue(coordinator.settings.enabled)
        XCTAssertNil(coordinator.eligibilitySource)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertTrue(client.additions.isEmpty)
        refreshContinuation?.resume(returning: try resetSnapshot(sequence: 2))
        await refresh.value
        XCTAssertEqual(client.additions.count, 1)
        XCTAssertEqual(coordinator.source, .iCloud)
    }

    func testICloudRevocationInvalidatesQueuedEligibilityBeforePendingOrAuthorizationWaitCompletes() async throws {
        for waitForAuthorization in [false, true] {
            let client = ReminderClient(); let coordinator = await configured(client)
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: .cloudflare)
            let oldPending = Set(client.pending.keys).union(client.unrelated)
            client.pausePending = !waitForAuthorization
            client.pauseReadAuthorization = waitForAuthorization
            let replacement = try resetSnapshot(sequence: 2, reset: stamp(resetNow.addingTimeInterval(9000)))
            let switching = Task { @MainActor in
                await coordinator.reconcile(snapshot: replacement, verified: true, now: resetNow, source: .iCloud)
            }
            try await waitUntil {
                waitForAuthorization ? client.authContinuation != nil : client.pendingContinuation != nil
            }
            XCTAssertEqual(coordinator.source, .cloudflare)
            XCTAssertEqual(coordinator.eligibilitySource, .iCloud)
            // Either owner can revoke: eligibility must not hide the existing
            // Cloudflare forecast while the iCloud replacement is suspended.
            XCTAssertTrue(PhoneResetReminderSourcePolicy.shouldCancel(source: coordinator.source,
                eligibilitySource: coordinator.eligibilitySource, cfRevoked: true, iCloudRevoked: false,
                cfEnabled: true, iCloudEnabled: true))
            let cancel = PhoneResetReminderSourcePolicy.shouldCancel(source: coordinator.source,
                eligibilitySource: coordinator.eligibilitySource, cfRevoked: false, iCloudRevoked: true,
                cfEnabled: true, iCloudEnabled: true)
            XCTAssertTrue(cancel)
            if cancel { coordinator.invalidateSource(now: resetNow) }
            XCTAssertTrue(client.pending.isEmpty, "Revocation removes known forecasts before the suspended operation finishes")
            XCTAssertNil(coordinator.eligibilitySource)
            if waitForAuthorization { client.authContinuation?.resume(returning: true) }
            else { client.pendingContinuation?.resume(returning: oldPending) }
            await switching.value
            await coordinator.reconcile(snapshot: nil, verified: false, now: resetNow)
            XCTAssertEqual(client.additions.count, 1, "Revoked queued iCloud eligibility cannot add a replacement")
            XCTAssertTrue(client.pending.isEmpty)
            XCTAssertNil(coordinator.source)
            XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
        }
    }

    func testLeadChangeAuthorizationWaitCannotReplaceDeliveredCycle() async throws {
        let time = ReminderClock(); let client = ReminderClient()
        let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { time.now })
        await coordinator.setEnabled(true, now: resetNow)
        await coordinator.setLeadMinutes(60, now: resetNow)
        let snapshot = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)))
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .iCloud)
        XCTAssertEqual(client.pending.values.first?.fireAt, resetNow.addingTimeInterval(60))
        client.pauseReadAuthorization = true
        let changing = Task { await coordinator.setLeadMinutes(5, now: resetNow) }
        try await waitUntil { client.authContinuation != nil }
        time.now = resetNow.addingTimeInterval(90)
        client.pending.removeAll() // The old request fires during authorization.
        client.authContinuation?.resume(returning: true)
        await changing.value
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.additions.count, 1)
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: time.now, source: .iCloud)
        XCTAssertEqual(client.additions.count, 1, "The delivered cycle remains suppressed on the next refresh")
    }

    func testLeadReplacementRechecksOldFireAfterUnrelatedAddSuspends() async throws {
        let time = ReminderClock(); let client = ReminderClient()
        let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { time.now })
        await coordinator.setEnabled(true, now: resetNow)
        await coordinator.setLeadMinutes(60, now: resetNow)
        let old = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)))
        await coordinator.reconcile(snapshot: old, verified: true, now: resetNow)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            resetSnapshot(count: 2, sequence: 2, reset: stamp(resetNow.addingTimeInterval(3660))))) as? [String: Any])
        var windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        var earlierWindow = try XCTUnwrap(windows[1]["window"] as? [String: Any])
        earlierWindow["resetsAt"] = stamp(resetNow.addingTimeInterval(1800))
        windows[1]["window"] = earlierWindow; object["windows"] = windows
        let batch = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        await coordinator.reconcile(snapshot: batch, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 1) // New window's 60-minute fire is already past.
        client.pauseAdd = true
        let changing = Task { await coordinator.setLeadMinutes(5, now: resetNow) }
        try await waitUntil { client.addContinuation != nil }
        XCTAssertEqual(client.additions.count, 2) // The earlier, unrelated window is added first.
        time.now = resetNow.addingTimeInterval(90)
        client.addContinuation?.resume()
        await changing.value
        XCTAssertEqual(client.additions.count, 2, "Old pending evidence cannot authorize a replacement after its fire deadline")
        XCTAssertEqual(client.pending.count, 1)
    }

    func testAcceptedICloudCatchInvalidatesBeforeSuspendedCloudflareRefresh() async throws {
        for enabled in [false, true] {
            let client = ReminderClient()
            let coordinator = ResetReminderCoordinator(storage: ReminderMemory(), client: client, clock: { resetNow })
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: .iCloud)
            if enabled { await coordinator.setEnabled(true, now: resetNow) }
            let identity = PhoneRefreshIdentity(generation: UUID(), credentialScope: "synthetic-scope", clientIdentifier: nil)
            let staleIdentity = PhoneRefreshIdentity(generation: UUID(), credentialScope: "synthetic-scope", clientIdentifier: nil)
            XCTAssertFalse(PhoneResetReminderSourcePolicy.acceptRevocation(source: .iCloud, coordinator: coordinator,
                identity: staleIdentity, currentIdentity: identity, transitioning: false,
                cfEnabled: true, iCloudEnabled: true, now: resetNow))
            XCTAssertEqual(coordinator.eligibilitySource, .iCloud)
            var cfContinuation: CheckedContinuation<Void, Never>?
            let refresh = Task { @MainActor in
                // Same accepted-catch helper and ordering as PhoneHost.refresh:
                // process the authoritative error before awaiting CF networking.
                XCTAssertTrue(PhoneResetReminderSourcePolicy.acceptRevocation(source: .iCloud, coordinator: coordinator,
                    identity: identity, currentIdentity: identity, transitioning: false,
                    cfEnabled: true, iCloudEnabled: true, now: resetNow))
                await withCheckedContinuation { cfContinuation = $0 }
            }
            try await waitUntil { cfContinuation != nil }
            XCTAssertTrue(client.pending.isEmpty, "Known iCloud forecasts are removed while CF is still suspended")
            XCTAssertNil(coordinator.eligibilitySource)
            if !enabled { await coordinator.setEnabled(true, now: resetNow) }
            XCTAssertTrue(client.pending.isEmpty)
            XCTAssertEqual(client.additions.count, enabled ? 1 : 0, "Revoked cached eligibility cannot schedule during CF networking")
            cfContinuation?.resume(); await refresh.value
            await coordinator.reconcile(snapshot: nil, verified: false, now: resetNow)
            XCTAssertTrue(client.pending.isEmpty)
        }
    }

    func testStartupLoadedTransportDisableCancelsBeforeActivityOrOtherTransportWaits() async throws {
        for owner in [ResetReminderSource.cloudflare, .iCloud] {
            for cachedOnly in [false, true] {
                let client = ReminderClient(); let storage = ReminderMemory()
                let original = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
                if !cachedOnly { await original.setEnabled(true, now: resetNow) }
                await original.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: owner)
                XCTAssertFalse(PhoneResetReminderSourcePolicy.reconcileTransportPreferences(coordinator: original,
                    cfEnabled: owner == .cloudflare, iCloudEnabled: owner == .iCloud, now: resetNow),
                    "Actual enabled preferences must preserve the owner despite initially false UI state")
                let ledgerBeforePreferenceWrite = storage.data
                // The independent preference write survived a crash; reminder
                // invalidation did not. No real defaults or user ledger is used.
                let preferences = try JSONEncoder().encode(["cfEnabled": owner == .iCloud, "iCloudEnabled": owner == .cloudflare])
                let loaded = try JSONDecoder().decode([String: Bool].self, from: preferences)
                let restored = cachedOnly ? original : ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
                XCTAssertEqual(storage.data, ledgerBeforePreferenceWrite)
                XCTAssertEqual(cachedOnly ? restored.eligibilitySource : restored.source, owner)
                var activityContinuation: CheckedContinuation<Void, Never>?
                var networkContinuation: CheckedContinuation<Void, Never>?
                let startup = Task { @MainActor in
                    // PhoneHost.task uses this synchronous prologue before its
                    // first ActivityKit await; restore repeats it before caches/network.
                    XCTAssertTrue(PhoneResetReminderSourcePolicy.reconcileTransportPreferences(coordinator: restored,
                        cfEnabled: loaded["cfEnabled"]!, iCloudEnabled: loaded["iCloudEnabled"]!, now: resetNow))
                    await withCheckedContinuation { activityContinuation = $0 }
                    XCTAssertFalse(PhoneResetReminderSourcePolicy.reconcileTransportPreferences(coordinator: restored,
                        cfEnabled: loaded["cfEnabled"]!, iCloudEnabled: loaded["iCloudEnabled"]!, now: resetNow))
                    await withCheckedContinuation { networkContinuation = $0 }
                    await restored.reconcile(snapshot: nil, verified: false, now: resetNow)
                }
                try await waitUntil { activityContinuation != nil }
                XCTAssertTrue(client.pending.isEmpty, "Disabled owner is cancelled before the first startup suspension")
                XCTAssertNil(restored.source); XCTAssertNil(restored.eligibilitySource)
                if cachedOnly { await restored.setEnabled(true, now: resetNow) }
                XCTAssertEqual(client.additions.count, cachedOnly ? 0 : 1)
                activityContinuation?.resume()
                try await waitUntil { networkContinuation != nil }
                XCTAssertTrue(client.pending.isEmpty, "No replacement snapshot is needed while the other transport waits")
                networkContinuation?.resume(); await startup.value
                XCTAssertTrue(client.pending.isEmpty)
                XCTAssertEqual(client.additions.count, cachedOnly ? 0 : 1)
                XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
            }
        }
    }

    func testCredentialCommitCrashBoundaryInvalidatesOldRequestsBeforeStartupNetwork() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 2), verified: true, now: resetNow, source: .cloudflare)
        let oldIDs = Set(client.pending.keys)
        client.deferRemoval = true
        var dummyViewer = "OLD_SYNTHETIC_VIEWER"
        let crashStorage = ReminderMemory()
        XCTAssertTrue(try PhoneResetReminderSourcePolicy.commitCredentialReplacement(coordinator: coordinator, now: resetNow) {
            let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
            XCTAssertEqual(Set(durable["credentialReplacementIDs"] as? [String] ?? []), oldIDs)
            XCTAssertNil(durable["scope"])
            XCTAssertNil(durable["source"])
            crashStorage.data = storage.data // Crash immediately after the independent credential write.
            dummyViewer = "NEW_SYNTHETIC_VIEWER"
        })
        XCTAssertEqual(dummyViewer, "NEW_SYNTHETIC_VIEWER")
        await coordinator.cancelAll(now: resetNow) // Drain only the simulated old process's callbacks.
        client.removed.removeAll()
        let restarted = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { resetNow })
        XCTAssertTrue(oldIDs.isSubset(of: Set(client.removed)), "Restart requests marked cleanup before any host await")
        var networkContinuation: CheckedContinuation<Void, Never>?
        let startup = Task { @MainActor in
            PhoneResetReminderSourcePolicy.reconcileTransportPreferences(coordinator: restarted,
                cfEnabled: true, iCloudEnabled: true, now: resetNow)
            await withCheckedContinuation { networkContinuation = $0 } // New pairing has no cached snapshot.
            await restarted.reconcile(snapshot: nil, verified: false, now: resetNow)
        }
        try await waitUntil { networkContinuation != nil }
        await restarted.reconcile(snapshot: nil, verified: false, now: resetNow)
        XCTAssertEqual(client.additions.count, 2)
        XCTAssertEqual(restarted.status.key, "resetReminder.suppressed")
        XCTAssertNil(restarted.source)
        client.finishRemoval(); client.deferRemoval = false
        networkContinuation?.resume(); await startup.value
        let next = try resetSnapshot(epoch: "replacement-epoch")
        await restarted.reconcile(snapshot: next, verified: true, now: resetNow, source: .cloudflare)
        XCTAssertEqual(client.additions.count, 3)
        XCTAssertTrue(oldIDs.isDisjoint(with: Set(client.pending.keys)))
        let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(crashStorage.data)) as? [String: Any])
        XCTAssertNil(durable["credentialReplacementIDs"], "Confirmed absence retires the transition marker before new scheduling")
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }

    func testCredentialCommitAbortsWhenAnyDurableInvalidationWriteFails() async throws {
        for failingWrite in [1, 2, 3] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            await coordinator.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow, source: .cloudflare)
            storage.failAtWrite = storage.writes + failingWrite
            var commits = 0
            let committed = try PhoneResetReminderSourcePolicy.commitCredentialReplacement(coordinator: coordinator, now: resetNow) {
                commits += 1 // Synthetic vault seam; never access real credentials.
            }
            XCTAssertFalse(committed)
            XCTAssertEqual(commits, 0)
            XCTAssertFalse(coordinator.settings.enabled)
            XCTAssertEqual(coordinator.status.key, "resetReminder.storageError")
            XCTAssertTrue(client.pending.isEmpty)
            await coordinator.setEnabled(true, now: resetNow)
            XCTAssertEqual(client.additions.count, 1)
        }
    }

    func testMacAccountIntentCrashBoundaryCancelsBeforeSuspendedWorkerRecovery() async throws {
        for mode in ["paused", "removed", "unreadable", "missing"] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            let snapshot = try resetSnapshot(count: 2)
            await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .local)
            let oldIDs = Set(client.pending.keys)
            let originalLedger = storage.data
            var connections: [[String: Any]] = [
                ["providerID": "codex", "accountID": "account-0", "isEnabled": false],
                ["providerID": "codex", "accountID": "account-1", "isEnabled": true]
            ]
            if mode == "removed" { connections.removeFirst() }
            let savedConfiguration = try JSONSerialization.data(withJSONObject: connections)
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
            XCTAssertEqual(storage.data, originalLedger, "Config write survived while the old reminder ledger remained unchanged")
            var workerContinuation: CheckedContinuation<Void, Never>?
            let startup = Task { @MainActor in
                // Same synchronous seam used at the start of MacModel.restore,
                // before bootstrap/projection/MCP/Worker awaits; no secrets or migration writes.
                ResetReminderStartupPolicy.restoreAccountIntent(coordinator: restarted, now: resetNow) {
                    if mode == "unreadable" { throw CocoaError(.fileReadNoPermission) }
                    if mode == "missing" { throw CocoaError(.fileReadNoSuchFile) }
                    let records = try XCTUnwrap(JSONSerialization.jsonObject(with: savedConfiguration) as? [[String: Any]])
                    return Set(try records.filter { $0["isEnabled"] as? Bool == true }.map {
                        ResetReminderPolicy.accountKey(providerID: try XCTUnwrap($0["providerID"] as? String),
                            accountID: try XCTUnwrap($0["accountID"] as? String))
                    })
                }
                await withCheckedContinuation { workerContinuation = $0 }
                await restarted.reconcile(snapshot: nil, verified: false, now: resetNow)
            }
            try await waitUntil { workerContinuation != nil }
            let retained = (mode == "paused" || mode == "removed") ? 1 : 0
            XCTAssertEqual(client.pending.count, retained, "Local persisted intent takes effect while Worker is still suspended")
            XCTAssertEqual(oldIDs.subtracting(client.pending.keys).count, 2 - retained)
            XCTAssertEqual(client.additions.count, 2)
            workerContinuation?.resume(); await startup.value
            XCTAssertEqual(client.pending.count, retained)
            XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
        }
    }

    func testUnconfirmedCancellationIDsSurviveRestartAndCredentialSaveCrash() async throws {
        for directReplacement in [false, true] {
            let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
            await coordinator.reconcile(snapshot: try resetSnapshot(count: 2), verified: true, now: resetNow, source: .cloudflare)
            let oldIDs = Set(client.pending.keys)
            client.deferRemoval = true
            if directReplacement { await coordinator.setLeadMinutes(5, now: resetNow) }
            else { await coordinator.setEnabled(false, now: resetNow) }
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
            XCTAssertEqual(Set((saved["cancelledRecords"] as? [String: Any])?.keys.map { $0 } ?? []), oldIDs)
            XCTAssertEqual(Set(client.pending.keys), oldIDs)
            client.removed.removeAll()
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
            XCTAssertTrue(oldIDs.isSubset(of: Set(client.removed)), "Restart immediately requests all unresolved cleanup IDs")
            let crashStorage = ReminderMemory()
            XCTAssertTrue(try PhoneResetReminderSourcePolicy.commitCredentialReplacement(coordinator: restarted, now: resetNow) {
                crashStorage.data = storage.data // Synthetic credential save crashes before OS removal completes.
                let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(crashStorage.data)) as? [String: Any])
                XCTAssertEqual(Set(durable["credentialReplacementIDs"] as? [String] ?? []), oldIDs)
            })
            await coordinator.cancelAll(now: resetNow); await restarted.cancelAll(now: resetNow)
            client.removed.removeAll()
            let afterCredentialCrash = ResetReminderCoordinator(storage: crashStorage, client: client, clock: { resetNow })
            XCTAssertTrue(oldIDs.isSubset(of: Set(client.removed)), "Credential crash cannot turn a still-pending owned set into an empty marker")
            await afterCredentialCrash.reconcile(snapshot: nil, verified: false, now: resetNow)
            XCTAssertEqual(Set(client.pending.keys), oldIDs)
            XCTAssertEqual(client.additions.count, 2)
            client.finishRemoval(); client.deferRemoval = false
            await afterCredentialCrash.reconcile(snapshot: nil, verified: false, now: resetNow)
            let retired = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(crashStorage.data)) as? [String: Any])
            XCTAssertEqual((retired["cancelledRecords"] as? [String: Any])?.count ?? 0, 0)
            XCTAssertNil(retired["credentialReplacementIDs"])
            XCTAssertTrue(client.pending.isEmpty)
        }
    }

    func testUnresolvedCleanupOccupancyStaysBoundedUntilConfirmedAbsent() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        await coordinator.reconcile(snapshot: try resetSnapshot(count: 48), verified: true, now: resetNow)
        client.deferRemoval = true
        let next = try resetSnapshot(epoch: "epoch-b")
        await coordinator.reconcile(snapshot: next, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 48)
        XCTAssertEqual(coordinator.status.key, "resetReminder.capped")
        let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
        XCTAssertEqual((ledger["cancelledRecords"] as? [String: Any])?.count, 48)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { resetNow })
        XCTAssertNotEqual(restarted.status.key, "resetReminder.storageError")
        client.finishRemoval(); client.deferRemoval = false
        await restarted.reconcile(snapshot: next, verified: true, now: resetNow)
        XCTAssertEqual(client.additions.count, 49)
        XCTAssertEqual(client.pending.count, 1)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
        XCTAssertEqual((updated["cancelledRecords"] as? [String: Any])?.count ?? 0, 0)
    }

    func testAcceptedMacAccountReplacementAndRollbackApplyBeforeActivationWaits() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        let original = try resetSnapshot(count: 2)
        await coordinator.reconcile(snapshot: original, verified: true, now: resetNow, source: .local)
        let oldRequest = try XCTUnwrap(ResetReminderPolicy.requests(snapshot: original, settings: coordinator.settings, now: resetNow)
            .first { $0.accountKey == ResetReminderPolicy.accountKey(providerID: "codex", accountID: "account-0") })
        let previousKeys = Set((0..<2).map { ResetReminderPolicy.accountKey(providerID: "codex", accountID: "account-\($0)") })
        let replacementKey = ResetReminderPolicy.accountKey(providerID: "codex", accountID: "replacement-account")
        let nextKeys = Set([replacementKey, ResetReminderPolicy.accountKey(providerID: "codex", accountID: "account-1")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resetSnapshot(count: 2, sequence: 2))) as? [String: Any])
        var windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        windows[0]["accountId"] = "replacement-account"; object["windows"] = windows
        let replacement = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        var persistedKeys = previousKeys
        var runtimeContinuation: CheckedContinuation<Void, Never>?
        var collectorContinuation: CheckedContinuation<Void, Never>?
        var rollbackContinuation: CheckedContinuation<Void, Never>?
        let changing = Task { @MainActor in
            // MacModel.persist routes every accepted configuration through this
            // synchronous seam before runtimeProvider/collector activation.
            try ResetReminderStartupPolicy.commitAccountIntent(coordinator: coordinator, accountKeys: nextKeys, now: resetNow) {
                persistedKeys = nextKeys
            }
            await withCheckedContinuation { runtimeContinuation = $0 }
            await coordinator.reconcile(snapshot: replacement, verified: true, now: resetNow, source: .local)
            await withCheckedContinuation { collectorContinuation = $0 }
            // An actual durable rollback uses the same boundary; merely
            // activating previous runtime state does not change accepted intent.
            try ResetReminderStartupPolicy.commitAccountIntent(coordinator: coordinator, accountKeys: previousKeys, now: resetNow) {
                persistedKeys = previousKeys
            }
            await withCheckedContinuation { rollbackContinuation = $0 }
            await coordinator.reconcile(snapshot: try resetSnapshot(count: 2, sequence: 3), verified: true, now: resetNow, source: .local)
        }
        try await waitUntil { runtimeContinuation != nil }
        XCTAssertEqual(persistedKeys, nextKeys)
        XCTAssertNil(client.pending[oldRequest.id], "Accepted replacement excludes the removed account before runtime activation")
        XCTAssertEqual(client.pending.count, 1)
        runtimeContinuation?.resume()
        try await waitUntil { collectorContinuation != nil }
        XCTAssertTrue(client.pending.values.contains { $0.accountKey == replacementKey })
        collectorContinuation?.resume()
        try await waitUntil { rollbackContinuation != nil }
        XCTAssertEqual(persistedKeys, previousKeys)
        XCTAssertFalse(client.pending.values.contains { $0.accountKey == replacementKey }, "Rollback excludes the replaced account before its own activation awaits")
        rollbackContinuation?.resume(); try await changing.value
        XCTAssertEqual(client.pending.count, 2)
        XCTAssertFalse(client.pending.values.contains { $0.accountKey == replacementKey })
        XCTAssertEqual(client.unrelated, ["billing-other", "other-app-feature"])
    }

    func testAmbiguousMacConfigWriteCancelsUntilSuccessfulDurableRollback() async throws {
        let client = ReminderClient(); let storage = ReminderMemory(); let coordinator = await configured(client, storage: storage)
        let snapshot = try resetSnapshot(count: 2)
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .local)
        let previous = Set((0..<2).map { ResetReminderPolicy.accountKey(providerID: "codex", accountID: "account-\($0)") })
        let next = Set([ResetReminderPolicy.accountKey(providerID: "codex", accountID: "replacement-account")])
        var persisted = previous
        XCTAssertThrowsError(try ResetReminderStartupPolicy.commitAccountIntent(coordinator: coordinator, accountKeys: next, now: resetNow) {
            persisted = next // Rename succeeded; durability acknowledgement then failed.
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(persisted, next)
        XCTAssertTrue(client.pending.isEmpty, "An ambiguous write establishes no enabled account before runtime fallback")
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .local)
        XCTAssertEqual(client.additions.count, 2, "Unpersisted fallback activation cannot re-enable the old account")
        try ResetReminderStartupPolicy.commitAccountIntent(coordinator: coordinator, accountKeys: previous, now: resetNow) {
            persisted = previous
        }
        await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow, source: .local)
        XCTAssertEqual(persisted, previous)
        XCTAssertEqual(client.pending.count, 2)
        XCTAssertEqual(client.additions.count, 4)
    }

    func testDeliveredAndPreparedSourceCyclesRemainSuppressedAcrossSwitchesAndRestart() async throws {
        for prepared in [false, true] {
            let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
            let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await coordinator.setEnabled(true, now: resetNow)
            await coordinator.setLeadMinutes(60, now: resetNow)
            let sourceA = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)), stale: resetNow.addingTimeInterval(9000))
            var recoveryStorage = storage
            if prepared {
                client.pauseAdd = true
                let adding = Task { await coordinator.reconcile(snapshot: sourceA, verified: true, now: resetNow) }
                try await waitUntil { client.addContinuation != nil }
                recoveryStorage = ReminderMemory(); recoveryStorage.data = storage.data
                client.addContinuation?.resume(); await adding.value
            } else { await coordinator.reconcile(snapshot: sourceA, verified: true, now: resetNow) }
            time.now = resetNow.addingTimeInterval(90); client.pending.removeAll()
            let recovered = ResetReminderCoordinator(storage: recoveryStorage, client: client, clock: { time.now })
            let sourceB = try resetSnapshot(epoch: "epoch-b", stale: resetNow.addingTimeInterval(9000))
            await recovered.reconcile(snapshot: sourceB, verified: true, now: time.now)
            await recovered.setLeadMinutes(5, now: time.now)
            await recovered.reconcile(snapshot: sourceA, verified: true, now: time.now)
            let aReplacement = try XCTUnwrap(ResetReminderPolicy.requests(snapshot: sourceA,
                settings: ResetReminderSettings(enabled: true, leadMinutes: 5), now: time.now).first)
            XCTAssertFalse(client.additions.contains(aReplacement.id))
            let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recoveryStorage.data)) as? [String: Any])
            XCTAssertNotNil((ledger["issuedCycles"] as? [String: Any])?[aReplacement.cycleID])
            let restarted = ResetReminderCoordinator(storage: recoveryStorage, client: client, clock: { time.now })
            await restarted.reconcile(snapshot: sourceB, verified: true, now: time.now)
            await restarted.reconcile(snapshot: sourceA, verified: true, now: time.now)
            XCTAssertFalse(client.additions.contains(aReplacement.id), "Source hashes preserve each active cycle across return and restart")
        }
    }

    func testDeferredRemovalCannotReleaseSuppressionAcrossCancellationPaths() async throws {
        for action in ["lead", "disable", "account", "revocation", "source", "permission", "offline"] {
            let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
            let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await coordinator.setEnabled(true, now: resetNow)
            await coordinator.setLeadMinutes(60, now: resetNow)
            let original = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)), stale: resetNow.addingTimeInterval(9000))
            await coordinator.reconcile(snapshot: original, verified: true, now: resetNow)
            let oldID = try XCTUnwrap(client.pending.keys.first)
            client.deferRemoval = true
            switch action {
            case "lead": await coordinator.setLeadMinutes(5, now: resetNow)
            case "disable": await coordinator.setEnabled(false, now: resetNow)
            case "account":
                coordinator.updateAllowedAccounts([], now: resetNow)
                await coordinator.reconcile(snapshot: original, verified: true, now: resetNow)
            case "revocation": await coordinator.reconcile(snapshot: try resetSnapshot(count: 0, sequence: 2), verified: true, now: resetNow)
            case "source": await coordinator.cancelAll(now: resetNow)
            case "permission":
                client.authorized = false
                await coordinator.reconcile(snapshot: original, verified: true, now: resetNow)
            default:
                await coordinator.reconcile(snapshot: original, verified: false, now: resetNow)
                await coordinator.setLeadMinutes(5, now: resetNow)
            }
            XCTAssertNotNil(client.pending[oldID], "Native-equivalent removal was requested but has not completed: \(action)")
            XCTAssertTrue(client.deferredRemoval.contains(oldID))
            XCTAssertEqual(client.additions.count, 1)
            time.now = resetNow.addingTimeInterval(90)
            client.pending.removeAll() // Old trigger fires before asynchronous removal takes effect.
            client.finishRemoval(); client.deferRemoval = false; client.authorized = true
            coordinator.updateAllowedAccounts(nil, now: time.now)
            await coordinator.setLeadMinutes(5, now: time.now)
            await coordinator.setEnabled(true, now: time.now)
            let fresh = try resetSnapshot(sequence: 3, reset: stamp(resetNow.addingTimeInterval(3660)),
                stale: resetNow.addingTimeInterval(9000))
            await coordinator.reconcile(snapshot: fresh, verified: true, now: time.now)
            XCTAssertEqual(client.additions.count, 1, "Unconfirmed cancellation cannot re-arm a potentially delivered cycle: \(action)")
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await restarted.reconcile(snapshot: fresh, verified: true, now: time.now)
            XCTAssertTrue(client.pending.isEmpty)
            XCTAssertEqual(client.additions.count, 1)
        }
    }

    func testDelayedCancellationEvidencePastDeadlineCannotReleaseCycle() async throws {
        for queued in [false, true] {
            let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
            let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await coordinator.setEnabled(true, now: resetNow)
            await coordinator.setLeadMinutes(60, now: resetNow)
            let snapshot = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)), stale: resetNow.addingTimeInterval(9000))
            await coordinator.reconcile(snapshot: snapshot, verified: true, now: resetNow)
            client.deferRemoval = true
            if queued { client.pausePending = true } // Positive pre-removal callback is delayed.
            else { client.pausePendingAt = client.pendingReads + 2 } // Post-removal callback is delayed.
            let cancelling = Task {
                if queued { await coordinator.setEnabled(false, now: resetNow) }
                else { await coordinator.setLeadMinutes(5, now: resetNow) }
            }
            try await waitUntil { client.pendingContinuation != nil }
            let before = client.capturedPending
            time.now = resetNow.addingTimeInterval(90); client.pending.removeAll()
            client.finishRemoval(); client.deferRemoval = false
            client.pendingContinuation?.resume(returning: queued ? before : client.unrelated)
            await cancelling.value
            await coordinator.setLeadMinutes(5, now: time.now)
            await coordinator.setEnabled(true, now: time.now)
            await coordinator.reconcile(snapshot: snapshot, verified: true, now: time.now)
            XCTAssertEqual(client.additions.count, 1, "Absence confirmed after the old fire time cannot prove it was cancelled before firing")
            let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
            await restarted.reconcile(snapshot: snapshot, verified: true, now: time.now)
            XCTAssertTrue(client.pending.isEmpty)
            XCTAssertEqual(client.additions.count, 1)
        }
    }

    func testForwardPastResetThenClockRewindFailsClosedAcrossRestartButStillCancels() async throws {
        let time = ReminderClock(); let client = ReminderClient(); let storage = ReminderMemory()
        let coordinator = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
        await coordinator.setEnabled(true, now: resetNow)
        await coordinator.setLeadMinutes(60, now: resetNow)
        let original = try resetSnapshot(reset: stamp(resetNow.addingTimeInterval(3660)), stale: resetNow.addingTimeInterval(9000))
        await coordinator.reconcile(snapshot: original, verified: true, now: resetNow)
        time.now = resetNow.addingTimeInterval(90); client.pending.removeAll()
        await coordinator.reconcile(snapshot: original, verified: true, now: time.now)
        time.now = resetNow.addingTimeInterval(4000)
        await coordinator.reconcile(snapshot: original, verified: true, now: time.now) // Expired cycle can be pruned.
        let later = try resetSnapshot(epoch: "epoch-b", reset: stamp(resetNow.addingTimeInterval(9000)), stale: resetNow.addingTimeInterval(10_000))
        await coordinator.reconcile(snapshot: later, verified: true, now: time.now)
        XCTAssertEqual(client.additions.count, 2)
        time.now = resetNow.addingTimeInterval(90)
        let restarted = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
        await restarted.reconcile(snapshot: try resetSnapshot(count: 0, epoch: "epoch-b", sequence: 2), verified: true, now: time.now)
        XCTAssertTrue(client.pending.isEmpty, "Authoritative cancellation precedes the backward-clock scheduling gate")
        await restarted.setLeadMinutes(5, now: time.now)
        await restarted.reconcile(snapshot: original, verified: true, now: time.now)
        XCTAssertEqual(client.additions.count, 2)
        XCTAssertEqual(restarted.status.key, "resetReminder.clockUncertain")
        let again = ResetReminderCoordinator(storage: storage, client: client, clock: { time.now })
        await again.reconcile(snapshot: original, verified: true, now: time.now)
        XCTAssertEqual(client.additions.count, 2)
        XCTAssertEqual(again.status.key, "resetReminder.clockUncertain")
    }

    func testCorruptOrUnwritableLedgerFailsClosed() async throws {
        let client = ReminderClient(); let bad = ReminderMemory(); bad.data = Data("not-json".utf8)
        let coordinator = ResetReminderCoordinator(storage: bad, client: client, clock: { resetNow })
        await coordinator.setEnabled(true, now: resetNow)
        XCTAssertFalse(coordinator.settings.enabled)
        XCTAssertEqual(coordinator.status.key, "resetReminder.storageError")
        let storage = ReminderMemory(); let valid = await configured(client, storage: storage)
        storage.fails = true
        await valid.reconcile(snapshot: try resetSnapshot(), verified: true, now: resetNow)
        XCTAssertFalse(valid.settings.enabled)
        XCTAssertTrue(client.pending.isEmpty)
    }
}
