import Foundation
import XCTest
import CryptoKit
import QuotaCore
@testable import QuotaSync

final class SnapshotClientCancellationTests: XCTestCase {
    private enum Kind: CaseIterable { case quota, usage }

    private actor Server {
        private var requests = 0
        private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        private var starts: [Int: CheckedContinuation<Void, Never>] = [:]
        let body: Data
        init(body: Data) { self.body = body }

        func receive(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
            requests += 1
            let number = requests
            await withCheckedContinuation { continuation in
                gates[number] = continuation
                starts.removeValue(forKey: number)?.resume()
            }
            // Deliberately ignore cancellation, like a response already queued
            // for delivery. The client must reject it before cache admission.
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["ETag": "fixture"])!)
        }
        func started(_ number: Int) async {
            if requests >= number { return }
            await withCheckedContinuation { starts[number] = $0 }
        }
        func release(_ number: Int) { gates.removeValue(forKey: number)?.resume() }
        func count() -> Int { requests }
    }

    private struct Fixture {
        let directory: URL
        let server: Server
        let refresh: @Sendable () async throws -> Int64?
        let cached: @Sendable () async throws -> Int64?
    }

    private func fixture(_ kind: Kind) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ammo-cancel-" + UUID().uuidString)
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "fixture", deviceID: "fixture", epoch: "fixture",
            keyID: "fixture", publicKey: signer.publicKey.rawRepresentation)
        let envelope: Data
        switch kind {
        case .quota:
            let value = try Snapshot.make(windows: [], deviceID: "fixture", epoch: "fixture",
                sequence: 2, capturedAt: Date())
            envelope = try EnvelopeCodec.seal(value, workspaceID: "fixture", keyID: "fixture", key: key, signingKey: signer)
        case .usage:
            let value = TokenUsageSnapshot(sourceDeviceId: "fixture", sourceEpoch: "fixture", sourceSequence: 2,
                capturedAt: "2026-10-02T05:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-02",
                sources: TokenUsageAgent.allCases.map { TokenUsageSource(agent: $0, status: .disabled) }, buckets: [])
            envelope = try UsageEnvelopeCodec.seal(value, workspaceID: "fixture", keyID: "fixture", key: key, signingKey: signer)
        }
        let body = try JSONSerialization.data(withJSONObject: ["envelope": JSONSerialization.jsonObject(with: envelope), "receipt": [:]])
        let server = Server(body: body)
        let transport = try SyncTransport(baseURL: URL(string: "https://fixture.example.invalid")!) { await server.receive($0) }
        switch kind {
        case .quota:
            let cache = try VerifiedCache(directory: directory, trust: trust)
            let client = SnapshotClient(transport: transport, cache: cache, token: "synthetic", key: key)
            return Fixture(directory: directory, server: server,
                refresh: { try await client.refresh()?.sourceSequence },
                cached: { try await client.cached()?.sourceSequence })
        case .usage:
            let cache = try VerifiedUsageCache(directory: directory, trust: trust)
            let client = UsageSnapshotClient(transport: transport, cache: cache, token: "synthetic", key: key)
            return Fixture(directory: directory, server: server,
                refresh: { try await client.refresh().snapshot?.sourceSequence },
                cached: { try await client.cached()?.sourceSequence })
        }
    }

    func testCancelledRefreshReturnsBeforeLateResponseAndDoesNotCommitIt() async throws {
        for kind in Kind.allCases {
            let fixture = try await fixture(kind)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cancelled = expectation(description: "\(kind) cancellation returns without response")
            let task = Task {
                defer { cancelled.fulfill() }
                do { _ = try await fixture.refresh(); XCTFail("Cancelled refresh succeeded") }
                catch is CancellationError {}
                catch { XCTFail("Unexpected error: \(error)") }
            }
            await fixture.server.started(1)
            task.cancel()
            await fulfillment(of: [cancelled], timeout: 1)
            await fixture.server.release(1)
            await task.value
            // Let the noncooperative response finish its rejected cache path.
            try await Task.sleep(for: .milliseconds(50))
            let cached = try await fixture.cached()
            XCTAssertNil(cached, "\(kind) committed a cancelled response")
        }
    }

    func testAlreadyCancelledRefreshDoesNotStartRequest() async throws {
        for kind in Kind.allCases {
            let fixture = try await fixture(kind)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await fixture.refresh(); XCTFail("Cancelled caller accepted") }
                catch is CancellationError {}
                catch { XCTFail("Unexpected error: \(error)") }
            }
            // A broken implementation must still be released to avoid hanging.
            try await Task.sleep(for: .milliseconds(50))
            let requests = await fixture.server.count()
            if requests > 0 { await fixture.server.release(1) }
            await task.value
            XCTAssertEqual(requests, 0, "\(kind) started a cancelled request")
        }
    }
}
