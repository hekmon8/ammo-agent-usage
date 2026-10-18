import Foundation
import XCTest
import QuotaCore
import QuotaStore
import CSQLite
@testable import QuotaProviders
@testable import QuotaCollector

private actor PartialFixtureFetchCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor PartialSyncSpy {
    var snapshots: [Snapshot] = []
    func record(_ value: Snapshot) { snapshots.append(value) }
}

private actor BlockingFreshGitHubFixture: QuotaProvider {
    nonisolated let actual: GitHubCLIProvider
    nonisolated var definition: ProviderDefinition { actual.definition }
    nonisolated var accountID: String { actual.accountID }
    nonisolated var credentialIdentity: String { actual.credentialIdentity }
    var started = false
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(actual: GitHubCLIProvider) { self.actual = actual }
    func githubExpenseObservedAt() async -> Date? { await actual.githubExpenseObservedAt() }
    func fetch(now: Date) async throws -> [QuotaWindow] {
        try await actual.fetch(now: now) { url, _ in
            await self.recordRequest()
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            await self.block()
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
            return Data("{\"timePeriod\":{\"year\":\(year),\"month\":\(month)},\"user\":\"demo-user\",\"usageItems\":[{\"product\":\"Actions\",\"sku\":\"runner\",\"unitType\":\"minutes\",\"netAmount\":9}]}".utf8)
        }
    }
    private func block() async { started = true; await withCheckedContinuation { continuation = $0 } }
    private func recordRequest() { requestCount += 1 }
    func release() { continuation?.resume(); continuation = nil }
}

private actor CancellableOtherFixture: QuotaProvider {
    nonisolated let definition = ProviderDefinition(id: "aaa-other", displayName: "Other synthetic", source: .userDefined)
    nonisolated let accountID = "synthetic-other"
    var started = false
    func fetch(now: Date) async throws -> [QuotaWindow] {
        started = true
        try await Task.sleep(for: .seconds(30))
        throw ProviderFailure.cancelled
    }
}

private struct UnknownGitHubFixtureProvider: QuotaProvider {
    let actual: GitHubCLIProvider
    var failure: ProviderFailure = .unsupported
    var count: PartialFixtureFetchCount? = nil
    var definition: ProviderDefinition { actual.definition }
    var accountID: String { actual.accountID }
    var credentialIdentity: String { actual.credentialIdentity }
    func retryNotBefore() async -> Date? { await actual.retryNotBefore() }
    func githubExpenseObservedAt() async -> Date? { await actual.githubExpenseObservedAt() }
    func fetch(now: Date) async throws -> [QuotaWindow] {
        await count?.increment()
        return try await actual.fetch(now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw failure
        }
    }
}

final class GitHubPartialCollectorTests: XCTestCase, @unchecked Sendable {
    func testSavedRateLimitedProbeDoesNotImmediatelyRequestAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let probe = try GitHubCLIProvider.normalized(report, alias: "Synthetic")
        let due = try XCTUnwrap(probe.retryNotBefore)
        let unknown = try XCTUnwrap(probe.windows.first)
        let store = try SnapshotStore(directory: directory)
        let actual = GitHubCLIProvider(accountID: probe.accountID, alias: "Synthetic", expectedIdentity: probe.identityFingerprint, organization: nil)
        let count = PartialFixtureFetchCount()
        let collector = try Collector(store: store, directory: directory,
            providers: [UnknownGitHubFixtureProvider(actual: actual, count: count)], deviceID: "synthetic", epoch: "synthetic",
            retryNotBefore: ["github-actions/" + probe.accountID: due])
        try await collector.start()
        try await collector.refresh()
        await collector.stop()
        XCTAssertEqual(unknown.availability, .unavailable)
        XCTAssertEqual(unknown.fetchOutcome, .throttled)
        XCTAssertNil(unknown.amount)
        XCTAssertNil(try AtomicSnapshotReader(directory: directory).latest(), "Saving a rate-limited identity must not fabricate a fetched snapshot")
        let calls = await count.value
        XCTAssertEqual(calls, 0)
        let diagnostics = await collector.diagnostics()
        XCTAssertEqual(diagnostics.first?.nextDue, due)
    }
    func testCollectorHonorsPartialSourcesRateLimitInsteadOfHealthyPollInterval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let normalized = try GitHubBillingReader.normalized(report, alias: "Synthetic")
        let actual = GitHubCLIProvider(accountID: normalized.accountID, alias: "Synthetic", expectedIdentity: normalized.identityFingerprint, organization: nil)
        let store = try SnapshotStore(directory: directory)
        let collector = try Collector(store: store, directory: directory,
            providers: [UnknownGitHubFixtureProvider(actual: actual, failure: .rateLimited(seconds: 600))], deviceID: "synthetic", epoch: "synthetic")
        try await collector.start()
        try await collector.refresh()
        let diagnostics = await collector.diagnostics()
        let due = try XCTUnwrap(diagnostics.first?.nextDue)
        XCTAssertGreaterThan(due.timeIntervalSince(now), 599)
        XCTAssertEqual(diagnostics.first?.outcome, .throttled)
        await collector.setRefreshInterval(.oneMinute)
        await collector.setLowPower(true)
        await collector.setLowPower(false)
        await collector.setSuspended(true)
        await collector.setSuspended(false)
        let rescheduled = await collector.diagnostics()
        XCTAssertEqual(rescheduled.first?.nextDue, due)
        try await collector.refresh()
        let manualRefresh = await collector.diagnostics()
        XCTAssertEqual(manualRefresh.first?.nextDue, due)
        await collector.stop()
    }
    func testThrottledReconnectInvalidatesOnlyRetainedExpenseAfterAcceptanceWithoutInitializationWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let probe = try GitHubBillingReader.normalized(report, alias: "Synthetic")
        let unknown = try XCTUnwrap(probe.windows.first)
        let old = QuotaWindow.providerValue(id: unknown.id, providerID: unknown.providerId, accountID: unknown.accountId,
            alias: unknown.accountAlias, key: unknown.quotaKey, unit: .money, currency: "USD", remainingBps: nil,
            amount: "8", limit: nil, quality: .reported, source: .officialAPI, observedAt: now,
            staleAt: now.addingTimeInterval(600), windowKind: .calendar, duration: nil, resetsAt: nil,
            startsAt: nil, periodID: unknown.window.periodId)
        let other = QuotaWindow.providerValue(id: "other-github-expense", providerID: "github-actions", accountID: "native-other",
            alias: "Other synthetic", key: "cost-spend", unit: .money, currency: "USD", remainingBps: nil,
            amount: "55", limit: nil, quality: .reported, source: .officialAPI, observedAt: now,
            staleAt: now.addingTimeInterval(600), windowKind: .calendar, duration: nil, resetsAt: nil)
        let otherProvider = GitHubCLIProvider(accountID: "native-other", alias: "Other synthetic", expectedIdentity: String(repeating: "f", count: 64), organization: nil)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old, other], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let actual = GitHubCLIProvider(accountID: probe.accountID, alias: "Synthetic", expectedIdentity: probe.identityFingerprint, organization: nil)
        let count = PartialFixtureFetchCount()
        let sync = PartialSyncSpy()
        let collector = try Collector(store: store, directory: directory, providers: [UnknownGitHubFixtureProvider(actual: actual, count: count), UnknownGitHubFixtureProvider(actual: otherProvider, count: count)],
            deviceID: "synthetic", epoch: "synthetic", retryNotBefore: ["github-actions/" + probe.accountID: try XCTUnwrap(probe.retryNotBefore), "github-actions/native-other": try XCTUnwrap(probe.retryNotBefore)], onPassComplete: { await sync.record($0) })
        try await collector.start()
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.first?.amount, "8", "Activation must not mutate the snapshot before acceptance")
        try await collector.publishRetainedGitHubInvalidation(failures: ["github-actions/" + probe.accountID: Date()])
        let published = try XCTUnwrap(AtomicSnapshotReader(directory: directory).latest()?.windows.first)
        XCTAssertEqual(published.id, old.id)
        XCTAssertNil(published.amount); XCTAssertNil(published.limit); XCTAssertNil(published.remainingBps)
        XCTAssertEqual(published.fetchOutcome, .throttled)
        XCTAssertEqual(published.availability, .unavailable)
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.last?.amount, "55")
        let calls = await count.value
        XCTAssertEqual(calls, 0)
        let forwarded = await sync.snapshots
        XCTAssertEqual(forwarded.count, 1, "Existing sync callback must receive invalidation without another API fetch")
        XCTAssertNil(forwarded.first?.windows.first?.amount)
        XCTAssertEqual(forwarded.first?.windows.first?.availability, .unavailable)
        await collector.stop()
    }

    func testQueuedInvalidationPreservesNewerActualAdapterResponseWithoutFutureDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.unsupported
        }
        let probe = try GitHubCLIProvider.normalized(report, alias: "Synthetic")
        let actual = GitHubCLIProvider(accountID: probe.accountID, alias: "Synthetic", expectedIdentity: probe.identityFingerprint, organization: nil)
        let provider = BlockingFreshGitHubFixture(actual: actual)
        let sync = PartialSyncSpy()
        let collector = try Collector(store: SnapshotStore(directory: directory), directory: directory,
            providers: [provider], deviceID: "synthetic", epoch: "synthetic", onPassComplete: { await sync.record($0) })
        try await collector.start()
        let pass = Task { try await collector.refresh() }
        while await !provider.started { await Task.yield() }
        // Produce a real failed report after collection started but before its
        // expense response completes, exercising the production reader clock.
        let failed = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.unsupported
        }
        let failedAt = try XCTUnwrap(failed.expenseObservedAt)
        let invalidation = Task { try await collector.publishRetainedGitHubInvalidation(failures: ["github-actions/" + probe.accountID: failedAt]) }
        await provider.release()
        try await pass.value
        try await invalidation.value
        let latestObservation = await actual.githubExpenseObservedAt()
        let observedAt = try XCTUnwrap(latestObservation)
        XCTAssertGreaterThan(observedAt, failedAt)
        XCTAssertLessThanOrEqual(observedAt, Date())
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.first?.amount, "9")
        let forwarded = await sync.snapshots
        XCTAssertEqual(forwarded.count, 1, "No false unavailable publication after newer recovery")
        await collector.stop()
    }

    func testQueuedInvalidationPublishesNewerResponseAfterOneShotStorageFailure() async throws {
        try await assertQueuedInvalidationAfterStorageFailure(recoverBeforeQueuedWrite: true)
    }

    func testQueuedInvalidationReportsPersistentStorageFailureAndCanRetryWithoutRefetch() async throws {
        try await assertQueuedInvalidationAfterStorageFailure(recoverBeforeQueuedWrite: false)
    }

    private func assertQueuedInvalidationAfterStorageFailure(recoverBeforeQueuedWrite: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.unsupported
        }
        let probe = try GitHubCLIProvider.normalized(report, alias: "Synthetic")
        let now = Date()
        let old = QuotaWindow.providerValue(id: "synthetic-old-expense", providerID: "github-actions", accountID: probe.accountID,
            alias: "Synthetic", key: "cost-spend", unit: .money, currency: "USD", remainingBps: nil, amount: "8", limit: nil,
            quality: .reported, source: .officialAPI, observedAt: now.addingTimeInterval(-60), staleAt: now.addingTimeInterval(600),
            windowKind: .calendar, duration: nil, resetsAt: nil)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let actual = GitHubCLIProvider(accountID: probe.accountID, alias: "Synthetic", expectedIdentity: probe.identityFingerprint, organization: nil)
        let provider = BlockingFreshGitHubFixture(actual: actual)
        let sync = PartialSyncSpy()
        let collector = try Collector(store: store, directory: directory, providers: [provider], deviceID: "synthetic", epoch: "synthetic",
            onProgress: { progress in
                // The failure callback runs before the active pass completes,
                // so the waiting invalidation sees a recovered store on retry.
                if progress == nil, recoverBeforeQueuedWrite {
                    try? Self.executeFixtureSQL("DROP TRIGGER IF EXISTS fail_publication", directory: directory)
                }
            }, onPassComplete: { await sync.record($0) })
        try await collector.start()
        let pass = Task { try await collector.refresh() }
        while await !provider.started { await Task.yield() }
        let failedAt = Date()
        try Self.executeFixtureSQL("CREATE TRIGGER fail_publication BEFORE INSERT ON latest_snapshot BEGIN SELECT RAISE(ABORT, 'synthetic publication failure'); END", directory: directory)
        let invalidation = Task { try await collector.publishRetainedGitHubInvalidation(failures: ["github-actions/" + probe.accountID: failedAt]) }
        await provider.release()
        do { try await pass.value; XCTFail("Injected publication must fail") }
        catch { XCTAssertEqual(error as? StoreError, .database) }
        if !recoverBeforeQueuedWrite {
            do { _ = try await invalidation.value; XCTFail("Persistent write failure must not report successful invalidation") }
            catch { XCTAssertEqual(error as? StoreError, .database) }
            let retained = try await store.latest()
            XCTAssertEqual(retained?.windows.first?.amount, "8")
            XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.first?.amount, "8")
            let unsynced = await sync.snapshots
            XCTAssertTrue(unsynced.isEmpty, "No success callback while the durable write is failing")
            try Self.executeFixtureSQL("DROP TRIGGER fail_publication", directory: directory)
        }
        let applied = recoverBeforeQueuedWrite ? try await invalidation.value
            : try await collector.publishRetainedGitHubInvalidation(failures: ["github-actions/" + probe.accountID: failedAt])
        XCTAssertTrue(applied)
        let durable = try await store.latest()
        XCTAssertEqual(durable?.windows.first?.amount, "9")
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.windows.first?.amount, "9")
        let forwarded = await sync.snapshots
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.windows.first?.amount, "9")
        let requests = await provider.requestCount
        XCTAssertEqual(requests, 2, "One identity request and one expense request; invalidation must not refetch")
        await collector.stop()
    }

    private static func executeFixtureSQL(_ sql: String, directory: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("quota.sqlite").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else { if let handle { sqlite3_close(handle) }; throw StoreError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }

    func testSuspendingActivePassDoesNotDropIndependentQueuedInvalidationOrSync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let old = QuotaWindow.providerValue(id: "synthetic-old-expense", providerID: "github-actions", accountID: "native-synthetic",
            alias: "Synthetic", key: "cost-spend", unit: .money, currency: "USD", remainingBps: nil, amount: "8", limit: nil,
            quality: .reported, source: .officialAPI, observedAt: now.addingTimeInterval(-1), staleAt: now.addingTimeInterval(600),
            windowKind: .calendar, duration: nil, resetsAt: nil)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let actual = GitHubCLIProvider(accountID: "native-synthetic", alias: "Synthetic", expectedIdentity: String(repeating: "f", count: 64), organization: nil)
        let count = PartialFixtureFetchCount()
        let other = CancellableOtherFixture()
        let sync = PartialSyncSpy()
        let collector = try Collector(store: store, directory: directory,
            providers: [other, UnknownGitHubFixtureProvider(actual: actual, count: count)], deviceID: "synthetic", epoch: "synthetic",
            retryNotBefore: ["github-actions/native-synthetic": now.addingTimeInterval(600)], onPassComplete: { await sync.record($0) })
        try await collector.start()
        let pass = Task { try await collector.refresh() }
        while await !other.started { await Task.yield() }
        let invalidation = Task { try await collector.publishRetainedGitHubInvalidation(failures: ["github-actions/native-synthetic": Date()]) }
        await collector.setSuspended(true)
        _ = try? await pass.value
        try await invalidation.value
        let forwarded = await sync.snapshots
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertNil(forwarded.first?.windows.first?.amount)
        XCTAssertEqual(forwarded.first?.windows.first?.availability, .unavailable)
        let requests = await count.value
        XCTAssertEqual(requests, 0)
        await collector.stop()
    }

    func testStoppedCollectorReportsPendingInvalidationAndAcceptedReplacementReplaysIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let key = "github-actions/native-synthetic"
        let old = QuotaWindow.providerValue(id: "synthetic-old-expense", providerID: "github-actions", accountID: "native-synthetic",
            alias: "Synthetic", key: "cost-spend", unit: .money, currency: "USD", remainingBps: nil, amount: "8", limit: nil,
            quality: .reported, source: .officialAPI, observedAt: now.addingTimeInterval(-1), staleAt: now.addingTimeInterval(600),
            windowKind: .calendar, duration: nil, resetsAt: nil)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let actual = GitHubCLIProvider(accountID: "native-synthetic", alias: "Synthetic", expectedIdentity: String(repeating: "f", count: 64), organization: nil)
        let count = PartialFixtureFetchCount()
        let sync = PartialSyncSpy()
        let (deadlines, failures) = try await stopWithQueuedInvalidation(directory: directory, store: store, actual: actual, count: count, sync: sync)
        // Disabling releases the old actor/lease; re-enabling creates a new
        // collector with the retained deadline and pending failure marker.
        let replacement = try Collector(store: store, directory: directory,
            providers: [UnknownGitHubFixtureProvider(actual: actual, count: count)], deviceID: "synthetic", epoch: "synthetic",
            retryNotBefore: deadlines, onPassComplete: { await sync.record($0) })
        try await replacement.start()
        let applied = try await replacement.publishRetainedGitHubInvalidation(failures: failures)
        XCTAssertTrue(applied)
        XCTAssertNil(try AtomicSnapshotReader(directory: directory).latest()?.windows.first?.amount)
        let forwarded = await sync.snapshots
        XCTAssertEqual(forwarded.count, 1)
        let calls = await count.value
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(deadlines[key])
        await replacement.stop()
    }

    private func stopWithQueuedInvalidation(directory: URL, store: SnapshotStore, actual: GitHubCLIProvider,
        count: PartialFixtureFetchCount, sync: PartialSyncSpy) async throws -> ([String: Date], [String: Date]) {
        let other = CancellableOtherFixture()
        let collector = try Collector(store: store, directory: directory,
            providers: [other, UnknownGitHubFixtureProvider(actual: actual, count: count)], deviceID: "synthetic", epoch: "synthetic",
            retryNotBefore: ["github-actions/native-synthetic": Date().addingTimeInterval(600)], onPassComplete: { await sync.record($0) })
        try await collector.start()
        let pass = Task { try await collector.refresh() }
        while await !other.started { await Task.yield() }
        let failures = ["github-actions/native-synthetic": Date()]
        let invalidation = Task { try await collector.publishRetainedGitHubInvalidation(failures: failures) }
        await collector.stop()
        _ = try? await pass.value
        let applied = try await invalidation.value
        XCTAssertFalse(applied, "Stopped collector must not claim pending invalidation is completed")
        return (await collector.retainedRetryDeadlines(), failures)
    }

    func testDisableReenableAndCollectorReplacementPreserveLearnedDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let probe = try GitHubBillingReader.normalized(report, alias: "Synthetic")
        let actual = GitHubCLIProvider(accountID: probe.accountID, alias: "Synthetic", expectedIdentity: probe.identityFingerprint, organization: nil)
        let count = PartialFixtureFetchCount()
        let provider = UnknownGitHubFixtureProvider(actual: actual, failure: .rateLimited(seconds: 600), count: count)
        let store = try SnapshotStore(directory: directory)
        var collector: Collector! = try Collector(store: store, directory: directory, providers: [provider], deviceID: "synthetic", epoch: "synthetic")
        try await collector.start(); try await collector.refresh()
        let deadlines = await collector.retainedRetryDeadlines()
        let key = "github-actions/" + probe.accountID
        let due = try XCTUnwrap(deadlines[key])
        await collector.setEnabled(false, key: key)
        await collector.setEnabled(true, key: key)
        let state = await collector.diagnostics()
        XCTAssertEqual(state.first?.nextDue, due)
        XCTAssertEqual(state.first?.outcome, .throttled)
        try await collector.refresh()
        await collector.stop()
        collector = nil // Release the old lease, matching MacModel.pauseCollector.
        let replacement = try Collector(store: store, directory: directory, providers: [provider], deviceID: "synthetic", epoch: "synthetic", retryNotBefore: deadlines)
        try await replacement.start(); try await replacement.refresh()
        let replacementState = await replacement.diagnostics()
        XCTAssertEqual(replacementState.first?.nextDue, due)
        let calls = await count.value
        XCTAssertEqual(calls, 1)
        await replacement.stop()
    }

    func testActualAdapter404ReplacesPreviouslyMeasuredCostWithUnknownInPublishedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw GitHubCLIFailure.billingUnavailable
        }
        let unknown = try GitHubBillingReader.normalized(report, alias: "Synthetic")
        let window = try XCTUnwrap(unknown.windows.first)
        let old = QuotaWindow.providerValue(id: window.id, providerID: window.providerId, accountID: window.accountId,
            alias: window.accountAlias, key: window.quotaKey, unit: .money, currency: "USD", remainingBps: nil,
            amount: "8", limit: nil, quality: .reported, source: .officialAPI, observedAt: now.addingTimeInterval(-60),
            staleAt: now.addingTimeInterval(540), windowKind: .calendar, duration: nil, resetsAt: nil,
            startsAt: nil, periodID: window.window.periodId)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let actual = GitHubCLIProvider(accountID: unknown.accountID, alias: "Synthetic",
            expectedIdentity: unknown.identityFingerprint, organization: nil)
        let collector = try Collector(store: store, directory: directory, providers: [UnknownGitHubFixtureProvider(actual: actual)],
            deviceID: "synthetic", epoch: "synthetic")
        try await collector.start()
        try await collector.refresh()
        await collector.stop()
        let published = try XCTUnwrap(AtomicSnapshotReader(directory: directory).latest()?.windows.first)
        XCTAssertEqual(published.id, old.id); XCTAssertEqual(published.accountId, old.accountId)
        XCTAssertEqual(published.availability, .unavailable)
        XCTAssertNil(published.amount); XCTAssertNil(published.remainingBps); XCTAssertNil(published.limit)
        XCTAssertEqual(QuotaPresentation(window: published, now: Date()).number, "—")
    }
}
