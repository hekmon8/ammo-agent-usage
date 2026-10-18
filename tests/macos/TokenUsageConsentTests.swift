import Foundation
import XCTest
import QuotaCore
import QuotaStore
@testable import QuotaSync
import CryptoKit
import QuotaProviders
import QuotaDesign
@testable import AmmoMac

final class TokenUsageConsentTests: XCTestCase {
    private final class ScanProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocking: Bool
        init(blocking: Bool = false) { self.blocking = blocking }
        func scan(_ roots: TokenUsageLogRoots, _ zone: TimeZone, _ device: String, _ epoch: String, _ sequence: Int64) throws -> TokenUsageSnapshot {
            lock.withLock { calls += 1 }
            if blocking {
                started.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
                try Task.checkCancellation()
            }
            let now = Date(), day = TokenUsageCalendar.day(now, in: zone)
            return TokenUsageSnapshot(sourceDeviceId: device, sourceEpoch: epoch, sourceSequence: sequence,
                capturedAt: ISO8601DateFormatter().string(from: now), timeZoneIdentifier: zone.identifier, retainedFromDay: day,
                sources: [TokenUsageSource(agent: .codex, status: .available)],
                buckets: [TokenUsageBucket(day: day, agent: .codex, tokens: TokenUsageCounts(output: 123))])
        }
    }

    @MainActor
    func testConsentRefreshTimezoneAndRestartUseSavedSettingsWithoutReadingWhileDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-settings-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), probe = ScanProbe()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token-usage.json")
        let model = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageScanner: probe.scan)
        await model.refreshTokenUsage()
        XCTAssertEqual(probe.count, 0)
        defaults.set(true, forKey: "ammo.tokenUsage.enabled")
        let enabled = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageScanner: probe.scan)
        await enabled.rescanTokenUsage(timeZoneIdentifier: "Asia/Singapore")
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(enabled.tokenUsage?.timeZoneIdentifier, "Asia/Singapore")
        XCTAssertFalse(enabled.tokenUsageIsStale())
        let sequence = try XCTUnwrap(enabled.tokenUsage).sourceSequence
        await enabled.refreshTokenUsage()
        XCTAssertEqual(enabled.tokenUsage?.buckets.first?.tokens.total, 123, "Refresh replaces rather than doubles totals")
        XCTAssertGreaterThan(try XCTUnwrap(enabled.tokenUsage).sourceSequence, sequence)
        let restarted = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageScanner: probe.scan)
        restarted.restoreTokenUsage(startLoop: false)
        XCTAssertTrue(restarted.tokenUsageEnabled)
        XCTAssertEqual(restarted.tokenUsageTimeZoneIdentifier, "Asia/Singapore")
        XCTAssertEqual(restarted.tokenUsage?.sourceSequence, enabled.tokenUsage?.sourceSequence)
        XCTAssertEqual(probe.count, 2, "Restore must not scan until a loop or refresh is requested")
        await restarted.setTokenUsageEnabled(false)
        await restarted.refreshTokenUsage()
        XCTAssertEqual(probe.count, 2)
        XCTAssertTrue(try XCTUnwrap(restarted.tokenUsage).isDisabledObservation)
        XCTAssertFalse(defaults.bool(forKey: "ammo.tokenUsage.enabled"))
        XCTAssertNotNil(TokenUsageText.diagnostic("logs_unavailable"))
        XCTAssertNil(TokenUsageText.diagnostic("/private/transcript/path"))
        XCTAssertNil(TokenUsageText.diagnostic("unknown_diagnostic"))
    }

    @MainActor
    func testDisableDuringScanCancelsBeforePublishingAndRetainsNoOldTotals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-cancel-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), probe = ScanProbe(blocking: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set(true, forKey: "ammo.tokenUsage.enabled")
        let model = MacModel(tokenUsageStorageURL: directory.appendingPathComponent("token-usage.json"), tokenUsageDefaults: defaults, tokenUsageScanner: probe.scan)
        let refresh = Task { await model.refreshTokenUsage() }
        for _ in 0..<100 where probe.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.count, 1)
        XCTAssertTrue(model.tokenUsageBusy)
        let disable = Task { await model.setTokenUsageEnabled(false) }
        for _ in 0..<100 where model.tokenUsageEnabled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.tokenUsageEnabled)
        probe.release.signal()
        await disable.value; await refresh.value
        XCTAssertFalse(model.tokenUsageBusy)
        XCTAssertTrue(try XCTUnwrap(model.tokenUsage).isDisabledObservation)
        XCTAssertTrue(try XCTUnwrap(model.tokenUsage).buckets.isEmpty)
    }

    @MainActor
    func testScanFailureRetainsLastLocalObservationAndMarksItStale() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-scan-failure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), probe = ScanProbe()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set(true, forKey: "ammo.tokenUsage.enabled")
        let file = directory.appendingPathComponent("token-usage.json")
        let good = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageScanner: probe.scan)
        await good.refreshTokenUsage()
        let failed = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageScanner: { _, _, _, _, _ in throw CocoaError(.fileReadNoPermission) })
        failed.restoreTokenUsage(startLoop: false)
        await failed.refreshTokenUsage()
        XCTAssertEqual(failed.tokenUsage?.buckets.first?.tokens.total, 123)
        XCTAssertNotNil(failed.tokenUsageMessage)
        XCTAssertNil(failed.tokenUsageSyncMessage)
        XCTAssertTrue(failed.tokenUsageIsStale())
    }
    @MainActor
    func testDisabledConsentClearsSidecarRetriesFailureAndRecoversOrphanOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-analysis-clear-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token-usage.json")
        let sidecar = directory.appendingPathComponent("token-usage-local-analysis.json")
        let historical = Data("synthetic-derived-cost-history".utf8)
        try PrivateFile.write(historical, to: sidecar)
        defaults.set(false, forKey: "ammo.tokenUsage.enabled")
        var fail = true, clears = 0
        let model = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults,
            tokenUsageAnalysisClear: { url in
                clears += 1
                if fail { throw CocoaError(.fileWriteUnknown) }
                try PrivateFile.write(Data(), to: url)
            }, tokenUsageScanner: { _, _, _, _, _ in XCTFail("Disabled cleanup cannot read logs"); throw CocoaError(.fileReadUnknown) })
        model.restoreTokenUsage(startLoop: false)
        XCTAssertTrue(try XCTUnwrap(model.tokenUsage).isDisabledObservation, "Sidecar failure must not block a sync tombstone")
        XCTAssertNil(model.tokenUsageLocalAnalysis)
        XCTAssertNotNil(model.tokenUsageMessage)
        XCTAssertEqual(try PrivateFile.read(sidecar, maxBytes: 100), historical)
        fail = false
        XCTAssertTrue(model.persistDisabledTokenUsage())
        XCTAssertEqual(clears, 2, "Cleanup retries even when the disabled snapshot is still fresh")
        XCTAssertTrue(try PrivateFile.read(sidecar, maxBytes: 100).isEmpty)
        XCTAssertNil(model.tokenUsageMessage)
        try PrivateFile.write(historical, to: sidecar)
        let restarted = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults)
        restarted.restoreTokenUsage(startLoop: false)
        XCTAssertTrue(try PrivateFile.read(sidecar, maxBytes: 100).isEmpty)
        // An interrupted deletion may leave a sidecar without a consent key or snapshot.
        try FileManager.default.removeItem(at: file)
        defaults.removeObject(forKey: "ammo.tokenUsage.enabled")
        try PrivateFile.write(historical, to: sidecar)
        MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults).restoreTokenUsage(startLoop: false)
        XCTAssertTrue(try PrivateFile.read(sidecar, maxBytes: 100).isEmpty)
    }

    @MainActor
    func testDisabledConsentReconcilesOldAggregateAfterCrashAndRetriesFailedWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-consent-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("token-usage.json")
        let old = TokenUsageSnapshot(sourceDeviceId: "synthetic", sourceEpoch: "epoch", sourceSequence: 5,
            capturedAt: "2026-10-02T05:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-02",
            sources: [TokenUsageSource(agent: .codex, status: .available)],
            buckets: [TokenUsageBucket(day: "2026-10-02", agent: .codex, tokens: TokenUsageCounts(output: 123))])
        try PrivateFile.write(TokenUsageSnapshotCodec.encode(old), to: file)
        // Simulate the crash boundary: consent reached disk, replacement did not.
        defaults.set(false, forKey: "ammo.tokenUsage.enabled")
        var fail = true
        let model = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageWrite: { data, url in
            if fail { throw CocoaError(.fileWriteUnknown) }
            try PrivateFile.write(data, to: url)
        })
        model.restoreTokenUsage(startLoop: false)
        XCTAssertFalse(model.tokenUsageEnabled)
        XCTAssertNil(model.tokenUsage, "Old enabled aggregate must never remain eligible for upload")
        XCTAssertNotNil(model.tokenUsageMessage)
        XCTAssertFalse(model.tokenUsageBusy, "Disabled reconciliation must not scan logs")
        XCTAssertEqual(try TokenUsageSnapshotCodec.decode(PrivateFile.read(file, maxBytes: TokenUsageSnapshotCodec.maxBytes)).buckets.first?.tokens.total, 123)
        fail = false
        XCTAssertTrue(model.persistDisabledTokenUsage())
        let disabled = try XCTUnwrap(model.tokenUsage)
        XCTAssertTrue(disabled.isDisabledObservation)
        XCTAssertGreaterThan(disabled.sourceSequence, old.sourceSequence)
        XCTAssertTrue(try TokenUsageSnapshotCodec.decode(PrivateFile.read(file, maxBytes: TokenUsageSnapshotCodec.maxBytes)).isDisabledObservation)
        let restarted = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults)
        restarted.restoreTokenUsage(startLoop: false)
        XCTAssertTrue(try XCTUnwrap(restarted.tokenUsage).isDisabledObservation)
        XCTAssertEqual(restarted.tokenUsage?.sourceSequence, disabled.sourceSequence)
    }
    @MainActor
    func testOfflinePhoneReceivesRenewedDisabledObservationAfterRemoteCiphertextExpiry() async throws {
        actor Server {
            var payload: Data?
            var lastSequence: Int64 = 0
            var lastHash = ""
            var puts = 0
            func expireCiphertext() { payload = nil }
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                if request.httpMethod == "PUT" {
                    puts += 1
                    let body = request.httpBody!
                    let envelope = try UsageEnvelopeCodec.decode(body)
                    if envelope.sequence > lastSequence {
                        lastSequence = envelope.sequence; lastHash = envelope.contentHash; payload = body
                    }
                    guard envelope.sequence == lastSequence, envelope.contentHash == lastHash else { throw TransportError.rejected(409) }
                    return (try JSONSerialization.data(withJSONObject: ["contentHash": lastHash, "sourceSequence": lastSequence]),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                guard let payload else { throw TransportError.rejected(404) }
                return (try JSONSerialization.data(withJSONObject: ["envelope": try JSONSerialization.jsonObject(with: payload), "receipt": [:]]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-expiry-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let capturedAt = ISO8601DateFormatter().string(from: oldDate)
        let day = TokenUsageCalendar.day(oldDate, in: TimeZone(identifier: "Etc/UTC")!)
        let enabled = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 1,
            capturedAt: capturedAt, timeZoneIdentifier: "Etc/UTC", retainedFromDay: day,
            sources: [TokenUsageSource(agent: .codex, status: .available)],
            buckets: [TokenUsageBucket(day: day, agent: .codex, tokens: TokenUsageCounts(output: 123))])
        let disabled = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 2,
            capturedAt: capturedAt, timeZoneIdentifier: "Etc/UTC", retainedFromDay: day,
            sources: TokenUsageAgent.allCases.map { TokenUsageSource(agent: $0, status: .disabled) }, buckets: [])
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let phoneCache = try VerifiedUsageCache(directory: directory.appendingPathComponent("phone"), trust: trust)
        _ = try await phoneCache.accept(UsageEnvelopeCodec.seal(enabled, workspaceID: "ws", keyID: "key", key: key, signingKey: signer), key: key)
        let server = Server(), endpoint = URL(string: "https://usage.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { try await server.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic",
            keyID: "key", signingPrivateKey: signer.rawRepresentation, snapshotKey: Data(repeating: 7, count: 32))
        let writer = try SyncWriter(credentials: credentials, directory: directory.appendingPathComponent("writer"), transport: transport)
        _ = try await writer.uploadUsage(disabled)
        await server.expireCiphertext() // Worker retains its replay watermark; ciphertext is gone.
        let file = directory.appendingPathComponent("token-usage.json")
        try PrivateFile.write(TokenUsageSnapshotCodec.encode(disabled), to: file)
        defaults.set(false, forKey: "ammo.tokenUsage.enabled")
        defaults.set("mac", forKey: "ammo.tokenUsage.device"); defaults.set("epoch", forKey: "ammo.tokenUsage.epoch")
        defaults.set(2, forKey: "ammo.tokenUsage.sequence")
        let model = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults)
        model.restoreTokenUsage(startLoop: false)
        let renewed = try XCTUnwrap(model.tokenUsage)
        XCTAssertGreaterThan(renewed.sourceSequence, disabled.sourceSequence, "Disabled snapshots must renew before their remote payload is lost")
        _ = try await writer.uploadUsage(renewed)
        let phone = UsageSnapshotClient(transport: transport, cache: phoneCache, token: "synthetic", key: key)
        let observation = try await phone.refresh()
        XCTAssertTrue(observation.verified)
        XCTAssertTrue(try XCTUnwrap(observation.snapshot).isDisabledObservation, "Returning offline phone must replace old enabled totals")
        let puts = await server.puts; XCTAssertEqual(puts, 2, "Saved receipt must not suppress the renewed disabled upload")
        XCTAssertFalse(model.tokenUsageBusy, "Tombstone renewal must never scan logs")
    }

    @MainActor
    func testDailyDisabledRenewalBoundaryWriteFailureRestartAndClockRewind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ammo-usage-renewal-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let initialDate = try XCTUnwrap(QuotaRules.date("2026-10-01T12:00:00Z"))
        let initial = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 2,
            capturedAt: "2026-10-01T12:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-01",
            sources: TokenUsageAgent.allCases.map { TokenUsageSource(agent: $0, status: .disabled) }, buckets: [])
        let file = directory.appendingPathComponent("token-usage.json")
        try PrivateFile.write(TokenUsageSnapshotCodec.encode(initial), to: file)
        defaults.set(false, forKey: "ammo.tokenUsage.enabled")
        defaults.set("mac", forKey: "ammo.tokenUsage.device"); defaults.set("epoch", forKey: "ammo.tokenUsage.epoch")
        defaults.set(2, forKey: "ammo.tokenUsage.sequence")
        var fail = false, writes = 0
        let model = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults, tokenUsageWrite: { data, url in
            writes += 1
            if fail { throw CocoaError(.fileWriteUnknown) }
            try PrivateFile.write(data, to: url)
        })
        model.restoreTokenUsage(startLoop: false, now: initialDate)
        XCTAssertTrue(model.persistDisabledTokenUsage(now: initialDate.addingTimeInterval(24 * 60 * 60 - 1)))
        XCTAssertEqual(model.tokenUsage?.sourceSequence, 2)
        XCTAssertEqual(writes, 0, "Five-minute polling must not create new ciphertext each time")
        fail = true
        XCTAssertFalse(model.persistDisabledTokenUsage(now: initialDate.addingTimeInterval(24 * 60 * 60)))
        XCTAssertNil(model.tokenUsage, "A failed renewal save is never eligible for upload")
        XCTAssertEqual(try TokenUsageSnapshotCodec.decode(PrivateFile.read(file, maxBytes: TokenUsageSnapshotCodec.maxBytes)).sourceSequence, 2)
        let restarted = MacModel(tokenUsageStorageURL: file, tokenUsageDefaults: defaults)
        let retryDate = initialDate.addingTimeInterval(24 * 60 * 60 + 300)
        restarted.restoreTokenUsage(startLoop: false, now: retryDate)
        let renewed = try XCTUnwrap(restarted.tokenUsage)
        XCTAssertTrue(renewed.isDisabledObservation)
        XCTAssertGreaterThan(renewed.sourceSequence, 3, "Restart must advance beyond the failed save sequence")
        XCTAssertEqual(renewed.capturedAt, ISO8601DateFormatter().string(from: retryDate))
        XCTAssertTrue(restarted.persistDisabledTokenUsage(now: retryDate.addingTimeInterval(300)))
        XCTAssertEqual(restarted.tokenUsage?.sourceSequence, renewed.sourceSequence)
        let rewind = retryDate.addingTimeInterval(-3600)
        XCTAssertTrue(restarted.persistDisabledTokenUsage(now: rewind))
        XCTAssertGreaterThan(try XCTUnwrap(restarted.tokenUsage).sourceSequence, renewed.sourceSequence)
        XCTAssertEqual(restarted.tokenUsage?.capturedAt, ISO8601DateFormatter().string(from: rewind))
        XCTAssertFalse(restarted.tokenUsageBusy)
    }

}
