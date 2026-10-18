import XCTest
import Foundation
import QuotaCore
import QuotaStore
import QuotaCollector
@testable import QuotaProviders
@testable import AmmoMac

private actor RecoveryFetchSpy {
    var calls = 0
    func called() { calls += 1 }
    var synced: [Snapshot] = []
    func sync(_ value: Snapshot) { synced.append(value) }
}
private struct RecoveryGitHubFixture: QuotaProvider {
    let definition = ProviderDefinition(id: "github-actions", displayName: "GitHub Actions", source: .officialAPI)
    let accountID: String
    let credentialIdentity: String
    let spy: RecoveryFetchSpy
    func fetch(now: Date) async throws -> [QuotaWindow] { await spy.called(); throw ProviderFailure.unsupported }
}
private actor RecoveryBlockingFixture: QuotaProvider {
    nonisolated let definition = ProviderDefinition(id: "aaa-blocked", displayName: "Synthetic", source: .userDefined)
    nonisolated let accountID = "synthetic"
    var started = false
    func fetch(now: Date) async throws -> [QuotaWindow] {
        started = true
        try await Task.sleep(for: .seconds(30))
        throw ProviderFailure.cancelled
    }
}

@MainActor
final class AmbientConnectionAcceptanceTests: XCTestCase {
    private enum Failure: Error { case activation, persistence }
    func testVerifiedGitHubWithUnavailableCostPersistsAndPreservesExistingConnection() async throws {
        let (previous, _, _) = try configurations()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw GitHubCLIFailure.billingUnavailable
        }
        let probe = try GitHubCLIProvider.normalized(report, alias: "Synthetic")
        let record = ProviderConnectionRecord(id: "local-github-" + String(probe.identityFingerprint.prefix(24)),
            kind: .githubCLILogin, providerID: "github-actions", accountID: probe.accountID,
            accountAlias: "Synthetic", expectedIdentity: probe.identityFingerprint)
        let next = try AmbientConnectionAcceptance.prepared(previous: previous, record: record, replacingID: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var installed: ProviderConnectionsConfiguration?
        _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
            persist: { try JSONEncoder().encode($0).write(to: file, options: .atomic) },
            install: { installed = $0 }, activate: { configuration in
                XCTAssertEqual(configuration.connections.count, 2)
                _ = try Snapshot.make(windows: probe.windows, deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: Date())
            }, pause: {}, cleanup: { $0 })
        let disk = try ProviderConnectionsConfiguration.decodeMigrating(Data(contentsOf: file)).configuration
        XCTAssertEqual(disk.connections.count, 2)
        XCTAssertEqual(disk.connections[0].id, previous.connections[0].id)
        XCTAssertEqual(disk.deviceID, previous.deviceID); XCTAssertEqual(disk.epoch, previous.epoch)
        XCTAssertEqual(disk.connections[1].expectedIdentity, probe.identityFingerprint)
        XCTAssertEqual(installed?.connections[1].id, record.id)
        XCTAssertNil(disk.connections[1].instanceID)
        XCTAssertNil(probe.windows[0].amount)
    }
    func testRejectedNewerProbeAndConnectionRollbackReplayPriorFailureWithoutAuthenticatingOldMoney() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let read: GitHubBillingReader.Request = { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let failure = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now, request: read)
        let failedProbe = try GitHubCLIProvider.normalized(failure, alias: "Synthetic")
        var state = GitHubPartialReadState(); state.observe(failedProbe)
        let priorState = state
        let window = try XCTUnwrap(failedProbe.windows.first)
        let old = QuotaWindow.providerValue(id: window.id, providerID: window.providerId, accountID: window.accountId,
            alias: window.accountAlias, key: window.quotaKey, unit: .money, currency: "USD", remainingBps: nil, amount: "8", limit: nil,
            quality: .reported, source: .officialAPI, observedAt: now.addingTimeInterval(-60), staleAt: now.addingTimeInterval(600),
            windowKind: .calendar, duration: nil, resetsAt: nil, periodID: window.window.periodId)
        let store = try SnapshotStore(directory: directory)
        try await store.publish(SnapshotCodec.encode(Snapshot.make(windows: [old], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)))
        let spy = RecoveryFetchSpy()
        let provider = RecoveryGitHubFixture(accountID: failedProbe.accountID, credentialIdentity: failedProbe.identityFingerprint, spy: spy)
        let pending = try await interruptQueuedFailure(directory: directory, store: store, provider: provider, state: state, spy: spy)
        XCTAssertFalse(pending)
        let healthy = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
            return Data("{\"timePeriod\":{\"year\":\(year),\"month\":\(month)},\"user\":\"demo-user\",\"usageItems\":[{\"product\":\"Actions\",\"sku\":\"runner\",\"unitType\":\"minutes\",\"netAmount\":9}]}".utf8)
        }
        let healthyProbe = try GitHubCLIProvider.normalized(healthy, alias: "Synthetic")
        state.observe(healthyProbe)
        XCTAssertEqual(state.unavailableExpenses, priorState.unavailableExpenses, "Uninstalled probe cannot clear prior failed expense intent")
        let oldRecord = ProviderConnectionRecord(id: "old", kind: .githubCLILogin, providerID: "github-actions",
            accountID: failedProbe.accountID, accountAlias: "Synthetic", expectedIdentity: failedProbe.identityFingerprint)
        let newRecord = ProviderConnectionRecord(id: "new", kind: .githubCLILogin, providerID: "github-actions",
            accountID: healthyProbe.accountID, accountAlias: "Synthetic", expectedIdentity: healthyProbe.identityFingerprint)
        let previous = try ProviderConnectionsConfiguration(deviceID: "synthetic", epoch: "synthetic", connections: [oldRecord]).validated()
        let next = try AmbientConnectionAcceptance.prepared(previous: previous, record: newRecord, replacingID: "old")
        var restored: Collector?
        do {
            _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { if $0.connections.first?.id == "new" { throw Failure.persistence } }, install: { _ in },
                activate: { _ in
                    restored = try Collector(store: store, directory: directory, providers: [provider], deviceID: "synthetic", epoch: "synthetic",
                        retryNotBefore: priorState.retryDeadlines, onPassComplete: { await spy.sync($0) })
                    try await restored?.start()
                }, pause: {}, cleanup: { $0 })
            XCTFail("Failed persistence accepted a new connection")
        } catch { XCTAssertTrue(error is Failure) }
        state = priorState
        let recovered = try XCTUnwrap(restored)
        await Task { @MainActor in
            _ = try? await recovered.publishRetainedGitHubInvalidation(failures: state.unavailableExpenses)
        }.value
        let saved = try XCTUnwrap(AtomicSnapshotReader(directory: directory).latest())
        XCTAssertNil(saved.windows.first?.amount)
        XCTAssertEqual(saved.windows.first?.availability, .unavailable)
        let calls = await spy.calls, synced = await spy.synced
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(synced.count, 1)
        XCTAssertNil(synced.first?.windows.first?.amount)
        await recovered.stop()
    }

    private func interruptQueuedFailure(directory: URL, store: SnapshotStore, provider: RecoveryGitHubFixture,
        state: GitHubPartialReadState, spy: RecoveryFetchSpy) async throws -> Bool {
        let blocked = RecoveryBlockingFixture()
        let collector = try Collector(store: store, directory: directory, providers: [blocked, provider], deviceID: "synthetic", epoch: "synthetic",
            retryNotBefore: state.retryDeadlines, onPassComplete: { await spy.sync($0) })
        try await collector.start()
        let pass = Task { try await collector.refresh() }
        while await !blocked.started { await Task.yield() }
        let invalidation = Task { try await collector.publishRetainedGitHubInvalidation(failures: state.unavailableExpenses) }
        await collector.stop()
        _ = try? await pass.value
        return try await invalidation.value
    }

    private func configurations() throws -> (ProviderConnectionsConfiguration, ProviderConnectionsConfiguration, String) {
        let instance = UUID().uuidString
        let old = ProviderConnectionRecord(id: "old", kind: .nativeProvider, providerID: "github-actions",
            accountID: "native-synthetic", accountAlias: "Synthetic", expectedIdentity: String(repeating: "f", count: 64), instanceID: instance)
        let new = ProviderConnectionRecord(id: "new", kind: .githubCLILogin, providerID: "github-actions",
            accountID: "native-synthetic", accountAlias: "Synthetic", expectedIdentity: String(repeating: "f", count: 64))
        let previous = try ProviderConnectionsConfiguration(deviceID: "synthetic", epoch: "synthetic", connections: [old]).validated()
        return (previous, try AmbientConnectionAcceptance.prepared(previous: previous, record: new, replacingID: "old"), instance)
    }
    func testActivationFailureRestoresDiskModelCollectorBeforeCleanup() async throws {
        let (previous, next, instance) = try configurations()
        XCTAssertEqual(next.pendingInstanceRemovals, [instance])
        var disk = previous, model = previous, running = previous
        var cleaned = false
        do {
            _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { disk = $0 }, install: { model = $0 }, activate: {
                    if $0.connections.first?.id == "new" { throw Failure.activation }
                    XCTAssertFalse(Task.isCancelled); running = $0
                }, pause: {}, cleanup: { cleaned = true; return $0 })
            XCTFail("Activation failure accepted")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(disk.connections.first?.id, "old")
        XCTAssertEqual(model.connections.first?.id, "old")
        XCTAssertEqual(running.connections.first?.id, "old")
        XCTAssertFalse(cleaned)
    }
    func testCancelledAcceptanceRestoresOutsideCancelledTask() async throws {
        let (previous, next, _) = try configurations()
        var disk = previous, model = previous
        let task = Task { @MainActor in
            try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { disk = $0 }, install: { model = $0 }, activate: {
                    if $0.connections.first?.id == "new" { try await Task.sleep(for: .seconds(20)) }
                    else { XCTAssertFalse(Task.isCancelled) }
                }, pause: {}, cleanup: { XCTFail("Cleanup before acceptance"); return $0 })
        }
        for _ in 0..<100 {
            if disk.connections.first?.id == "new" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled acceptance succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(disk.connections.first?.id, "old")
        XCTAssertEqual(model.connections.first?.id, "old")
    }
    func testCleanupFailureRetainsDurablePendingCredentialRemovalForRetry() async throws {
        let (previous, next, instance) = try configurations()
        var disk = previous
        let accepted = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
            persist: { disk = $0 }, install: { _ in }, activate: { _ in }, pause: {}, cleanup: { $0 })
        XCTAssertEqual(accepted.connections.first?.id, "new")
        XCTAssertNil(accepted.connections.first?.instanceID)
        XCTAssertEqual(disk.pendingInstanceRemovals, [instance])
        XCTAssertEqual(accepted.pendingInstanceRemovals, [instance])
    }
    func testPersistenceThatThrowsAfterDiskReplacementStillRollsBack() async throws {
        let (previous, next, _) = try configurations()
        var disk = previous, model = previous, running = previous
        var cleaned = false
        do {
            _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { disk = $0; if $0.connections.first?.id == "new" { throw Failure.persistence } },
                install: { model = $0 }, activate: {
                    XCTAssertEqual(disk.connections.first?.id, "old"); running = $0
                }, pause: {}, cleanup: { cleaned = true; return $0 })
            XCTFail("Partial persistence failure accepted")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(disk.connections.first?.id, "old")
        XCTAssertEqual(model.connections.first?.id, "old")
        XCTAssertEqual(running.connections.first?.id, "old")
        XCTAssertFalse(cleaned)
    }
    func testActualCleanupOperationsFailThenRetryAfterAcceptance() throws {
        let (_, next, instance) = try configurations()
        var disk = next, deletionAttempts = 0, profileAttempts = 0
        let failed = AmbientConnectionAcceptance.cleanup(next, persist: { disk = $0 },
            removeCredential: { XCTAssertEqual($0, instance); deletionAttempts += 1; throw Failure.persistence },
            removeProfile: { _ in profileAttempts += 1 })
        XCTAssertEqual(failed.pendingInstanceRemovals, [instance])
        XCTAssertEqual(disk.pendingInstanceRemovals, [instance])
        XCTAssertEqual(profileAttempts, 0)
        let retried = AmbientConnectionAcceptance.cleanup(failed, persist: { disk = $0 },
            removeCredential: { XCTAssertEqual($0, instance); deletionAttempts += 1 },
            removeProfile: { XCTAssertEqual($0, instance); profileAttempts += 1 })
        XCTAssertEqual(deletionAttempts, 2); XCTAssertEqual(profileAttempts, 1)
        XCTAssertEqual(retried.pendingInstanceRemovals, [])
        XCTAssertEqual(disk.pendingInstanceRemovals, [])
        XCTAssertEqual(disk.connections.first?.id, "new")
    }
    func testLegacyManualVaultFailureIsDistinctFromKnownPersonalScope() throws {
        let (previous, _, _) = try configurations()
        let record = try XCTUnwrap(previous.connections.first)
        XCTAssertNil(record.organizationID)
        XCTAssertEqual(GitHubReconnectScope.resolve(record: record, loadOrganization: { throw Failure.persistence }), .unavailable)
        XCTAssertEqual(GitHubReconnectScope.resolve(record: record, loadOrganization: { nil }), .known(nil))
        XCTAssertEqual(GitHubReconnectScope.resolve(record: record, loadOrganization: { "demo-org" }), .known("demo-org"))
    }
    func testRollbackPersistenceFailureIsVisible() async throws {
        let (previous, next, _) = try configurations()
        do {
            _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { if $0.connections.first?.id == "old" { throw Failure.persistence } },
                install: { _ in }, activate: { _ in throw Failure.activation }, pause: {}, cleanup: { $0 })
            XCTFail("Recovery failure was hidden")
        } catch { XCTAssertTrue(error is AmbientConnectionAcceptance.RecoveryFailure) }
    }
}
