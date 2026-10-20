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
        private var responses: [Int: Bool] = [:]
        private var completions: [Int: CheckedContinuation<Bool, Never>] = [:]
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
            responses[number] = Task.isCancelled
            completions.removeValue(forKey: number)?.resume(returning: Task.isCancelled)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["ETag": "fixture"])!)
        }
        func started(_ number: Int) async {
            if requests >= number { return }
            await withCheckedContinuation { starts[number] = $0 }
        }
        func release(_ number: Int) { gates.removeValue(forKey: number)?.resume() }
        func count() -> Int { requests }
        func responseWasCancelled(_ number: Int) async -> Bool {
            if let cancelled = responses[number] { return cancelled }
            return await withCheckedContinuation { completions[number] = $0 }
        }
    }

    private struct Fixture {
        let directory: URL
        let server: Server
        let refresh: @Sendable () async throws -> Int64?
        let cached: @Sendable () async throws -> Int64?
        let waiterCount: @Sendable () async -> Int
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
                cached: { try await client.cached()?.sourceSequence },
                waiterCount: { await client.refreshWaiterCount })
        case .usage:
            let cache = try VerifiedUsageCache(directory: directory, trust: trust)
            let client = UsageSnapshotClient(transport: transport, cache: cache, token: "synthetic", key: key)
            return Fixture(directory: directory, server: server,
                refresh: { try await client.refresh().snapshot?.sourceSequence },
                cached: { try await client.cached()?.sourceSequence },
                waiterCount: { await client.refreshWaiterCount })
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
            let cancelledResponse = await fixture.server.responseWasCancelled(1)
            XCTAssertTrue(cancelledResponse, "\(kind) left the underlying pull running")
            let cached = try await fixture.cached()
            XCTAssertNil(cached, "\(kind) committed a cancelled response")
        }
    }

    func testAlreadyCancelledRefreshDoesNotStartRequest() async throws {
        for kind in Kind.allCases {
            let fixture = try await fixture(kind)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let returned = expectation(description: "\(kind) pre-cancelled caller returns")
            let task = Task {
                defer { returned.fulfill() }
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await fixture.refresh(); XCTFail("Cancelled caller accepted") }
                catch is CancellationError {}
                catch { XCTFail("Unexpected error: \(error)") }
            }
            await fulfillment(of: [returned], timeout: 1)
            // Release an unexpected request even on regression failure.
            let requests = await fixture.server.count()
            if requests > 0 { await fixture.server.release(1) }
            await task.value
            XCTAssertEqual(requests, 0, "\(kind) started a cancelled request")
        }
    }

    private func waitForWaiters(_ count: Int, in fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.waiterCount() != count {
            if ContinuousClock.now >= deadline {
                XCTFail("Refresh waiters did not register")
                throw TransportError.unavailable
            }
            await Task.yield()
        }
    }

    func testCancellingOneRegisteredWaiterPreservesSharedForegroundPull() async throws {
        for kind in Kind.allCases {
            let fixture = try await fixture(kind)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let background = Task { try await fixture.refresh() }
            await fixture.server.started(1)
            let foreground = Task { try await fixture.refresh() }
            try await waitForWaiters(2, in: fixture)
            background.cancel()
            do { _ = try await background.value; XCTFail("Cancelled waiter succeeded") }
            catch is CancellationError {}
            let waiters = await fixture.waiterCount()
            XCTAssertEqual(waiters, 1)
            await fixture.server.release(1)
            let value = try await foreground.value
            let requests = await fixture.server.count()
            let cancelledResponse = await fixture.server.responseWasCancelled(1)
            XCTAssertEqual(value, 2)
            XCTAssertEqual(requests, 1)
            XCTAssertFalse(cancelledResponse)
        }
    }

    func testLastWaiterCancellationAllowsImmediateRetryAndIgnoresOldFlight() async throws {
        for kind in Kind.allCases {
            let fixture = try await fixture(kind)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let first = Task { try await fixture.refresh() }
            await fixture.server.started(1)
            let second = Task { try await fixture.refresh() }
            try await waitForWaiters(2, in: fixture)
            first.cancel()
            do { _ = try await first.value; XCTFail("First cancellation ignored") }
            catch is CancellationError {}
            second.cancel()
            do { _ = try await second.value; XCTFail("Last cancellation ignored") }
            catch is CancellationError {}
            let replacement = Task { try await fixture.refresh() }
            await fixture.server.started(2)
            await fixture.server.release(1)
            let oldCancelled = await fixture.server.responseWasCancelled(1)
            XCTAssertTrue(oldCancelled)
            let replacementWaiters = await fixture.waiterCount()
            XCTAssertEqual(replacementWaiters, 1)
            await fixture.server.release(2)
            let value = try await replacement.value
            XCTAssertEqual(value, 2)
            let cached = try await fixture.cached()
            XCTAssertEqual(cached, 2)
            // Usage cancellation must not become a cached failure for 10 seconds.
            let throttled = try await fixture.refresh()
            let requests = await fixture.server.count()
            XCTAssertEqual(throttled, 2)
            XCTAssertEqual(requests, 2)
        }
    }
}
