import Foundation
import XCTest
import QuotaCore
import QuotaStore
import QuotaProviders
@testable import QuotaCollector

private actor StubProvider: QuotaProvider {
    nonisolated let definition = ProviderDefinition(id: "test", displayName: "Test", source: .userDefined)
    nonisolated let accountID = "test_account"
    var calls = 0
    func fetch(now: Date) async throws -> [QuotaWindow] {
        calls += 1
        try await Task.sleep(for: .milliseconds(80))
        return [.reported(id: "test-primary", providerID: "test", accountID: accountID, alias: "Test", key: "primary", remainingBps: 6800, observedAt: now, staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined)]
    }
}
private actor StubProviderNamed: QuotaProvider {
    nonisolated let definition: ProviderDefinition
    nonisolated let accountID: String
    nonisolated let windowID: String
    init(id: String, accountID: String, windowID: String) {
        definition = ProviderDefinition(id: id, displayName: id, source: .userDefined)
        self.accountID = accountID
        self.windowID = windowID
    }
    func fetch(now: Date) async throws -> [QuotaWindow] {
        [.reported(id: windowID, providerID: definition.id, accountID: accountID,
            alias: definition.id, key: "primary", remainingBps: 6_800, observedAt: now,
            staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined)]
    }
}
final class CollectorTests: XCTestCase {
    func testIntervalChangesRescheduleFromLastFetchAndRestoreAfterLowPower() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        let collector = try Collector(store: SnapshotStore(directory: directory), directory: directory,
                                      providers: [provider], deviceID: "mac", epoch: "epoch")
        await collector.setRefreshInterval(.thirtyMinutes)
        try await collector.start()
        try await collector.refresh()
        let initial = await collector.diagnostics()
        let initialDue = try XCTUnwrap(initial.first?.nextDue)
        let attempted = initialDue.addingTimeInterval(-1800)

        await collector.setRefreshInterval(.oneMinute)
        let faster = await collector.diagnostics()
        XCTAssertEqual(try XCTUnwrap(faster.first?.nextDue).timeIntervalSince(attempted), 60, accuracy: 0.001)
        await collector.setLowPower(true)
        let lowPower = await collector.diagnostics()
        XCTAssertEqual(try XCTUnwrap(lowPower.first?.nextDue).timeIntervalSince(attempted), 900, accuracy: 0.001)
        await collector.setRefreshInterval(.sixtyMinutes)
        let slower = await collector.diagnostics()
        XCTAssertEqual(try XCTUnwrap(slower.first?.nextDue).timeIntervalSince(attempted), 3600, accuracy: 0.001)
        await collector.setRefreshInterval(.twoMinutes)
        await collector.setLowPower(false)
        let restored = await collector.diagnostics()
        XCTAssertEqual(try XCTUnwrap(restored.first?.nextDue).timeIntervalSince(attempted), 120, accuracy: 0.001)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1, "Changing preferences must not launch an extra request")
        await collector.stop()
    }

    func testIntervalChangesPreserveFailureDeadlinesAndPausedProviders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = FailingProvider(id: "auth", failure: .authRequired)
        let rate = FailingProvider(id: "rate", failure: .rateLimited(seconds: 7200))
        let network = FailingProvider(id: "network", failure: .network)
        let paused = StubProvider()
        let collector = try Collector(store: SnapshotStore(directory: directory), directory: directory,
                                      providers: [auth, rate, network, paused], deviceID: "mac", epoch: "epoch")
        await collector.setEnabled(false, key: "test/test_account")
        try await collector.start()
        try await collector.refresh()
        let before = await collector.diagnostics()
        await collector.setRefreshInterval(.oneMinute)
        await collector.setLowPower(true)
        await collector.setRefreshInterval(.sixtyMinutes)
        await collector.setLowPower(false)
        let after = await collector.diagnostics()
        XCTAssertEqual(after.map(\.nextDue), before.map(\.nextDue))
        XCTAssertEqual(after.map(\.outcome), before.map(\.outcome))
        XCTAssertNil(after.first { $0.providerID == "test" }?.nextDue)
        let calls = await paused.calls
        XCTAssertEqual(calls, 0)
        await collector.stop()
    }

    func testPausedInstanceRetainsObservationWhileAnotherAccountUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let paused = FailingProvider(id: "paused", failure: .network)
        let active = StubProvider()
        let observedAt = Date().addingTimeInterval(-60)
        let historical = QuotaWindow.reported(id: "paused-primary", providerID: "paused", accountID: "test_account",
            alias: "Paused", key: "primary", remainingBps: 3200, observedAt: observedAt,
            staleAt: observedAt.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [historical], deviceID: "mac_test",
            epoch: "epoch_test", sequence: 1, capturedAt: observedAt)))
        let collector = try Collector(store: store, directory: directory, providers: [paused, active],
            deviceID: "mac_test", epoch: "epoch_test")
        await collector.setEnabled(false, key: "paused/test_account")
        try await collector.start()
        try await collector.refresh()
        let calls = await paused.calls
        XCTAssertEqual(calls, 0)
        let retained = try AtomicSnapshotReader(directory: directory).latest()?.windows.first { $0.id == historical.id }
        XCTAssertEqual(retained?.observedAt, historical.observedAt)
        XCTAssertEqual(retained?.remainingBps, 3200)
        await collector.stop()
    }

    func testRefreshKeepsWindowOrderSoDashboardCardsDoNotJump() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date().addingTimeInterval(-120)
        func window(_ id: String, provider: String, account: String) -> QuotaWindow {
            .reported(id: id, providerID: provider, accountID: account, alias: provider,
                key: "primary", remainingBps: 5_000, observedAt: now, staleAt: now.addingTimeInterval(3_600),
                duration: nil, resetsAt: nil, source: .userDefined)
        }
        try await store.publish(SnapshotCodec.encode(Snapshot.make(
            windows: [window("a-primary", provider: "alpha", account: "alpha_account"),
                      window("b-primary", provider: "beta", account: "test_account")],
            deviceID: "mac_test", epoch: "epoch_test", sequence: 1, capturedAt: now)))
        // Only alpha updates in this pass; beta keeps its slot and its historical value.
        let alpha = StubProviderNamed(id: "alpha", accountID: "alpha_account", windowID: "a-primary")
        let beta = FailingProvider(id: "beta", failure: .network)
        let collector = try Collector(store: store, directory: directory, providers: [alpha, beta],
            deviceID: "mac_test", epoch: "epoch_test")
        try await collector.start()
        try? await collector.refresh()
        let ids = try AtomicSnapshotReader(directory: directory).latest()?.windows.map(\.id)
        XCTAssertEqual(ids, ["a-primary", "b-primary"])
        await collector.stop()
    }

    func testRefreshCoalescesAndPublishesSingleSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory), provider = StubProvider()
        let collector = try Collector(store: store, directory: directory, providers: [provider], deviceID: "mac_test", epoch: "epoch_test")
        try await collector.start()
        async let first: Void = collector.refresh()
        async let second: Void = collector.refresh()
        try await first; try await second
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.sourceSequence, 1)
        await collector.stop()
        do { try await collector.refresh(); XCTFail("refresh after stop") } catch StoreError.unavailable {}
    }
}

private actor FailingProvider: QuotaProvider {
    nonisolated let definition: ProviderDefinition
    nonisolated let accountID = "test_account"
    let failure: ProviderFailure
    var calls = 0
    init(id: String, failure: ProviderFailure) { definition = ProviderDefinition(id: id, displayName: id, source: .userDefined); self.failure = failure }
    func fetch(now: Date) async throws -> [QuotaWindow] { calls += 1; throw failure }
}
extension CollectorTests {
    func testAuthenticationRetriesAtLowFrequencyAndRateLimitRetainsRetryDeadline() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-backoff-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = FailingProvider(id: "auth", failure: .authRequired), throttled = FailingProvider(id: "rate", failure: .rateLimited(seconds: 120))
        let collector = try Collector(store: SnapshotStore(directory: directory), directory: directory, providers: [auth, throttled], deviceID: "mac", epoch: "epoch")
        try await collector.start(); try? await collector.refresh()
        let health = await collector.diagnostics()
        XCTAssertEqual(health.first { $0.providerID == "auth" }?.outcome, .authRequired)
        // An expired login is probed again on a low fixed cadence instead of
        // parking the account until a manual reconnect.
        XCTAssertGreaterThan(health.first { $0.providerID == "auth" }?.nextDue?.timeIntervalSinceNow ?? 0, 1700)
        XCTAssertGreaterThan(health.first { $0.providerID == "rate" }?.nextDue?.timeIntervalSinceNow ?? 0, 118)
        try? await collector.refresh()
        let authCalls = await auth.calls, rateCalls = await throttled.calls
        XCTAssertEqual(authCalls, 1); XCTAssertEqual(rateCalls, 1)
        await collector.stop()
    }
}

private actor ConcurrencyProbe {
    private(set) var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

private actor AccountProvider: QuotaProvider {
    nonisolated let definition: ProviderDefinition
    nonisolated let accountID: String
    nonisolated let credentialIdentity: String
    private let probe: ConcurrencyProbe

    init(providerID: String, accountID: String, probe: ConcurrencyProbe) {
        definition = ProviderDefinition(id: providerID, displayName: providerID, source: .userDefined)
        self.accountID = accountID
        credentialIdentity = providerID + "-" + accountID
        self.probe = probe
    }

    func fetch(now: Date) async throws -> [QuotaWindow] {
        await probe.enter()
        do { try await Task.sleep(for: .milliseconds(60)) }
        catch { await probe.leave(); throw error }
        await probe.leave()
        return [.reported(
            id: definition.id + "-" + accountID + "-primary", providerID: definition.id,
            accountID: accountID, alias: accountID, key: "primary", remainingBps: 7_500,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil,
            source: .userDefined
        )]
    }
}

private actor FixedWindowsProvider: QuotaProvider {
    nonisolated let definition: ProviderDefinition
    nonisolated let accountID: String
    nonisolated let credentialIdentity: String
    private let windows: [QuotaWindow]

    init(providerID: String, accountID: String, windows: [QuotaWindow]) {
        definition = ProviderDefinition(id: providerID, displayName: providerID, source: .userDefined)
        self.accountID = accountID
        credentialIdentity = providerID + "-" + accountID
        self.windows = windows
    }

    func fetch(now _: Date) async throws -> [QuotaWindow] { windows }
}
private actor SlowProvider: QuotaProvider {
    nonisolated let definition = ProviderDefinition(id: "zslow", displayName: "Slow", source: .userDefined)
    nonisolated let accountID = "slow_account"
    func fetch(now: Date) async throws -> [QuotaWindow] {
        try await Task.sleep(for: .milliseconds(500))
        return [.reported(id: "slow-primary", providerID: "zslow", accountID: accountID,
            alias: "Slow", key: "primary", remainingBps: 6_000, observedAt: now,
            staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined)]
    }
}

private actor ProgressRecorder {
    private(set) var events: [CollectorProgress?] = []
    func record(_ progress: CollectorProgress?) { events.append(progress) }
}
private actor PassRecorder {
    private(set) var snapshots: [Snapshot] = []
    func record(_ snapshot: Snapshot) { snapshots.append(snapshot) }
}



extension CollectorTests {
    func testScheduledRefreshPublishesFirstAccountBeforeSlowAccountAndReportsProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let progress = ProgressRecorder()
        let completedPasses = PassRecorder()
        let collector = try Collector(store: store, directory: directory,
            providers: [StubProvider(), SlowProvider()], deviceID: "mac", epoch: "epoch",
            onProgress: { await progress.record($0) },
            onPassComplete: { await completedPasses.record($0) })
        try await collector.start()
        // The scheduled tick, not an explicit refresh, must launch the first pass.
        var first: Snapshot?
        for _ in 0..<40 {
            first = try AtomicSnapshotReader(directory: directory).latest()
            if first != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(first?.windows.map(\.providerId), ["test"])
        XCTAssertEqual(first?.sourceSequence, 1)
        var final: Snapshot?
        for _ in 0..<60 {
            final = try AtomicSnapshotReader(directory: directory).latest()
            if final?.windows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Set(final?.windows.map(\.providerId) ?? []), ["test", "zslow"])
        // Incremental local snapshots are visible while the remote fan-out has
        // exactly one complete snapshot to send for the entire account pass.
        for _ in 0..<20 {
            if await completedPasses.snapshots.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = await completedPasses.snapshots
        XCTAssertEqual(completed.map(\.sourceSequence), [final?.sourceSequence].compactMap { $0 })
        XCTAssertEqual(completed.first?.windows.count, 2)
        let events = await progress.events
        XCTAssertTrue(events.contains { $0?.completed == 1 && $0?.total == 2 })
        await collector.stop()
    }

    func testMultipleAccountsUseOneSequentialCollectorAndStayIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ConcurrencyProbe()
        let first = AccountProvider(providerID: "bridge", accountID: "account_a", probe: probe)
        let second = AccountProvider(providerID: "bridge", accountID: "account_b", probe: probe)
        let collector = try Collector(
            store: SnapshotStore(directory: directory), directory: directory, providers: [first, second],
            deviceID: "mac", epoch: "epoch"
        )
        try await collector.start()
        try await collector.refresh(providerID: "bridge")
        let windows = await collector.current()
        let maximum = await probe.maximum
        XCTAssertEqual(Set(windows.map(\.accountId)), ["account_a", "account_b"])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(maximum, 1)
        await collector.stop()
    }

    func testOversizedOrDuplicateAdapterResultPreservesPreviousSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date()
        let retained = QuotaWindow.reported(
            id: "retained-id", providerID: "old", accountID: "old_account", alias: "Old", key: "primary",
            remainingBps: 8_000, observedAt: now, staleAt: now.addingTimeInterval(600), duration: nil,
            resetsAt: nil, source: .userDefined
        )
        try await store.publish(SnapshotCodec.encode(try Snapshot.make(
            windows: [retained], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now
        )))
        let old = FixedWindowsProvider(providerID: "old", accountID: "old_account", windows: [retained])
        // One more than the snapshot budget so the proposed set must be rejected.
        let overflowWindows = (0..<SnapshotCodec.maxWindows).map { index in
            QuotaWindow.reported(
                id: "overflow-\(index)", providerID: "overflow", accountID: "overflow_account",
                alias: "Overflow", key: "q\(index)", remainingBps: 5_000, observedAt: now,
                staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined
            )
        }
        let overflow = FixedWindowsProvider(providerID: "overflow", accountID: "overflow_account",
                                            windows: overflowWindows)
        let duplicateWindow = QuotaWindow.reported(
            id: retained.id, providerID: "duplicate", accountID: "duplicate_account", alias: "Duplicate",
            key: "primary", remainingBps: 4_000, observedAt: now, staleAt: now.addingTimeInterval(600),
            duration: nil, resetsAt: nil, source: .userDefined
        )
        let duplicate = FixedWindowsProvider(providerID: "duplicate", accountID: "duplicate_account",
                                             windows: [duplicateWindow])
        let collector = try Collector(
            store: store, directory: directory, providers: [old, overflow, duplicate],
            deviceID: "mac", epoch: "epoch"
        )
        try await collector.start()
        try await collector.refresh(providerID: "overflow")
        let afterOverflow = await collector.current().map(\.id)
        XCTAssertEqual(afterOverflow, [retained.id])
        try await collector.refresh(providerID: "duplicate")
        let afterDuplicate = await collector.current().map(\.id)
        XCTAssertEqual(afterDuplicate, [retained.id])
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.map(\.id), [retained.id])
        let health = await collector.diagnostics()
        XCTAssertEqual(health.first { $0.providerID == "overflow" }?.outcome, .error)
        XCTAssertEqual(health.first { $0.providerID == "duplicate" }?.outcome, .error)
        await collector.stop()
    }
}
