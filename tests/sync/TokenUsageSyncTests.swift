import Foundation
import XCTest
import CryptoKit
import QuotaCore
import QuotaStore
@testable import QuotaSync

final class TokenUsageSyncTests: XCTestCase {
    private let endpoint = URL(string: "https://usage.example.invalid")!
    private func snapshot(_ sequence: Int64, epoch: String = "epoch") -> TokenUsageSnapshot {
        TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: epoch, sourceSequence: sequence,
            capturedAt: "2026-10-02T05:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-09-01",
            sources: [TokenUsageSource(agent: .codex, status: .available)],
            buckets: [TokenUsageBucket(day: "2026-10-02", agent: .codex,
                tokens: TokenUsageCounts(nonCachedInput: 100, cacheRead: 20, output: 30))])
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ammo-usage-" + UUID().uuidString) }
    private func credentials(_ signer: Curve25519.Signing.PrivateKey) -> WriterCredentials {
        WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic",
            keyID: "key", signingPrivateKey: signer.rawRepresentation, snapshotKey: Data(repeating: 7, count: 32))
    }
    func testUsageEncryptionBindsSourceAndCannotCrossQuotaDomain() throws {
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let bytes = try UsageEnvelopeCodec.seal(snapshot(1), workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        XCTAssertEqual(try UsageEnvelopeCodec.open(bytes, trust: trust, key: key).buckets.first?.tokens.total, 150)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("nonCachedInput"))
        XCTAssertThrowsError(try EnvelopeCodec.open(bytes, trust: trust, key: key))
        let quota = try Snapshot.make(windows: [], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: Date())
        XCTAssertThrowsError(try UsageEnvelopeCodec.open(EnvelopeCodec.seal(quota, workspaceID: "ws", keyID: "key", key: key, signingKey: signer), trust: trust, key: key))
        let other = SourceTrust(workspaceID: "ws", deviceID: "second-mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        XCTAssertThrowsError(try UsageEnvelopeCodec.open(bytes, trust: other, key: key))
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["ciphertext"] = Base64URL.encode(Data(repeating: 1, count: 131_073))
        XCTAssertThrowsError(try UsageEnvelopeCodec.decode(JSONSerialization.data(withJSONObject: object)))
        object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["extra"] = "disallowed"
        XCTAssertThrowsError(try UsageEnvelopeCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testVerifiedUsageCacheRejectsReplayAndKeepsQuotaAndNewSourceIsolated() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedUsageCache(directory: directory, trust: trust)
        let first = try UsageEnvelopeCodec.seal(snapshot(3), workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        _ = try await cache.accept(first, key: key)
        _ = try await cache.accept(first, key: key)
        for sequence in [2, 3] {
            let replay = try UsageEnvelopeCodec.seal(snapshot(Int64(sequence)), workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
            do { _ = try await cache.accept(replay, key: key); XCTFail("replay accepted") } catch SyncError.replay {}
        }
        do { _ = try await cache.accept(Data("bad json".utf8), key: key); XCTFail("bad cache accepted") } catch {}
        let retained = try await cache.latest(key: key)
        XCTAssertEqual(retained?.sourceSequence, 3)
        let quotaCache = try VerifiedCache(directory: directory, trust: trust)
        let quota = try await quotaCache.latest(key: key)
        XCTAssertNil(quota)
        let newTrust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "new-epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let next = try VerifiedUsageCache(directory: directory, trust: newTrust)
        let absent = try await next.latest(key: key)
        XCTAssertNil(absent)
    }
    func testUsagePendingIsByteIdenticalAcrossRestartAndRecoversSavedAcknowledgement() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let pending = try PendingUsageEnvelope(directory: directory)
        let first = try await pending.prepare(snapshot: snapshot(1), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        let restarted = try PendingUsageEnvelope(directory: directory)
        let retry = try await restarted.prepare(snapshot: snapshot(2), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        XCTAssertEqual(first, retry)
        let e = try UsageEnvelopeCodec.decode(first)
        try await restarted.discardAcknowledged(sequence: e.sequence, contentHash: e.contentHash)
        let next = try await restarted.prepare(snapshot: snapshot(2), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        XCTAssertEqual(try UsageEnvelopeCodec.decode(next).sequence, 2)
        XCTAssertNotEqual(next, first)
    }
    func testUsageFailureAndOldWorkerDoNotBlockQuotaAndRetryUsesIdenticalBytes() async throws {
        actor Server {
            var usageBodies: [Data] = []; var quotaCount = 0
            var unavailable = true
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                let isUsage = request.url!.path == "/v1/usage"
                if isUsage {
                    usageBodies.append(request.httpBody!)
                    if unavailable { unavailable = false; throw TransportError.unavailable }
                } else { quotaCount += 1 }
                let e = try EnvelopeCodec.decode(request.httpBody!)
                return (try JSONSerialization.data(withJSONObject: ["contentHash": e.contentHash, "sourceSequence": e.sequence]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server(), signer = Curve25519.Signing.PrivateKey()
        let transport = try SyncTransport(baseURL: endpoint) { try await server.receive($0) }
        let writer = try SyncWriter(credentials: credentials(signer), directory: directory, transport: transport)
        do { _ = try await writer.uploadUsage(snapshot(1)); XCTFail("network failure ignored") } catch TransportError.unavailable {}
        try await writer.upload(Snapshot.make(windows: [], deviceID: "local", epoch: "local", sequence: 1, capturedAt: Date()))
        let restarted = try SyncWriter(credentials: credentials(signer), directory: directory, transport: transport)
        let success = try await restarted.uploadUsage(snapshot(2)); XCTAssertTrue(success)
        let bodies = await server.usageBodies, quotaCount = await server.quotaCount
        XCTAssertEqual(bodies.count, 3); XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(quotaCount, 1)
        XCTAssertEqual(try UsageEnvelopeCodec.decode(bodies[2]).sequence, 2)
        let olderWorker = try SyncTransport(baseURL: endpoint) { _ in throw TransportError.rejected(404) }
        let otherDirectory = self.directory(); defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let old = try SyncWriter(credentials: credentials(signer), directory: otherDirectory, transport: olderWorker)
        let supported = try await old.uploadUsage(snapshot(1)); XCTAssertFalse(supported)
    }
    func testUsageClientConditionalReadAndUnsupportedWorkerKeepLastGoodTimestamp() async throws {
        actor Server {
            let envelope: Data
            var count = 0; var validators: [String?] = []
            init(_ envelope: Data) { self.envelope = envelope }
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                count += 1; validators.append(request.value(forHTTPHeaderField: "If-None-Match"))
                if count == 3 { throw TransportError.rejected(404) }
                if count == 4 { return (Data("invalid".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
                let object: [String: Any] = ["envelope": try JSONSerialization.jsonObject(with: envelope), "receipt": [:]]
                return (count == 1 ? try JSONSerialization.data(withJSONObject: object) : Data(),
                    HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 200 : 304, httpVersion: nil, headerFields: ["ETag": "usage-1"])!)
            }
        }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedUsageCache(directory: directory, trust: trust)
        let server = Server(try UsageEnvelopeCodec.seal(snapshot(1), workspaceID: "ws", keyID: "key", key: key, signingKey: signer))
        let client = UsageSnapshotClient(transport: try SyncTransport(baseURL: endpoint) { try await server.receive($0) }, cache: cache, token: "synthetic", key: key)
        for offset in [0, 11, 22] {
            let value = try await client.refresh(now: Date(timeIntervalSince1970: Double(offset)))
            XCTAssertEqual(value.snapshot?.capturedAt, "2026-10-02T05:00:00Z")
            XCTAssertEqual(value.verified, offset != 22)
        }
        let validators = await server.validators
        XCTAssertNil(validators[0]); XCTAssertEqual(validators[1], "usage-1")
        do { _ = try await client.refresh(now: Date(timeIntervalSince1970: 33)); XCTFail("invalid body accepted") } catch {}
        let last = try await client.cached(); XCTAssertEqual(last?.sourceSequence, 1)
    }
    func testUsageDisableSupersedesUnsentEnabledEnvelopeAndRemainsStableAcrossRestart() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let pending = try PendingUsageEnvelope(directory: directory)
        let old = try await pending.prepare(snapshot: snapshot(1), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        let disabled = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 2,
            capturedAt: "2026-10-02T06:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-02",
            sources: TokenUsageAgent.allCases.map { TokenUsageSource(agent: $0, status: .disabled) }, buckets: [])
        let replacement = try await pending.prepare(snapshot: disabled, workspaceID: "ws", keyID: "key", key: key, signer: signer)
        XCTAssertNotEqual(replacement, old)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        XCTAssertTrue(try UsageEnvelopeCodec.open(replacement, trust: trust, key: key).isDisabledObservation)
        let restarted = try PendingUsageEnvelope(directory: directory)
        let retry = try await restarted.prepare(snapshot: disabled, workspaceID: "ws", keyID: "key", key: key, signer: signer)
        XCTAssertEqual(retry, replacement)
    }

    func testUsageThrottlePreservesFailureUntilSuccessfulVerification() async throws {
        actor Server {
            let envelope: Data
            var attempts = 0
            init(_ envelope: Data) { self.envelope = envelope }
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                attempts += 1
                if attempts == 1 { throw TransportError.unavailable }
                let object: [String: Any] = ["envelope": try JSONSerialization.jsonObject(with: envelope), "receipt": [:]]
                return (try JSONSerialization.data(withJSONObject: object),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "usage-1"])!)
            }
        }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedUsageCache(directory: directory, trust: trust)
        let envelope = try UsageEnvelopeCodec.seal(snapshot(1), workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        _ = try await cache.accept(envelope, key: key)
        let server = Server(envelope)
        let client = UsageSnapshotClient(transport: try SyncTransport(baseURL: endpoint) { try await server.receive($0) }, cache: cache, token: "synthetic", key: key)
        for offset in [0, 1] {
            do { _ = try await client.refresh(now: Date(timeIntervalSince1970: Double(offset))); XCTFail("Failure became success during throttle") }
            catch TransportError.unavailable {}
        }
        let attempts = await server.attempts; XCTAssertEqual(attempts, 1)
        let value = try await client.refresh(now: Date(timeIntervalSince1970: 11))
        XCTAssertTrue(value.verified)
        XCTAssertEqual(value.snapshot?.sourceSequence, 1)
    }

}
