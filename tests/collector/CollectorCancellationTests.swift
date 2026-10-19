import Foundation
import XCTest
import QuotaCore
import QuotaStore
import QuotaProviders
@testable import QuotaCollector

private actor CancellationGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitForArrival() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { release?.resume(); release = nil }
}

private actor CancellationProvider: QuotaProvider {
    nonisolated let definition = ProviderDefinition(id: "test", displayName: "Test", source: .userDefined)
    nonisolated let accountID = "test_account"
    let gate: CancellationGate
    private var first = true
    private(set) var calls = 0

    init(gate: CancellationGate) { self.gate = gate }
    func retryNotBefore() async -> Date? {
        if first { first = false; await gate.hold() }
        return nil
    }
    func fetch(now: Date) async throws -> [QuotaWindow] {
        calls += 1
        return [.reported(id: "test-primary", providerID: "test", accountID: accountID,
            alias: "Test", key: "primary", remainingBps: 6800, observedAt: now,
            staleAt: now.addingTimeInterval(600), duration: nil, resetsAt: nil, source: .userDefined)]
    }
}

final class CollectorCancellationTests: XCTestCase, @unchecked Sendable {
    func testReenabledRefreshDoesNotInheritCancelledPass() async throws {
        try await checkRefresh(reenable: true, cancelCaller: false)
    }

    func testDisabledProviderDoesNotRestartAfterCancelledPass() async throws {
        try await checkRefresh(reenable: false, cancelCaller: false)
    }

    func testCancelledRefreshCallerDoesNotRestartPass() async throws {
        try await checkRefresh(reenable: true, cancelCaller: true)
    }

    private func checkRefresh(reenable: Bool, cancelCaller: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CancellationGate(), provider = CancellationProvider(gate: gate)
        let collector = try Collector(store: SnapshotStore(directory: directory), directory: directory,
            providers: [provider], deviceID: "synthetic", epoch: "synthetic")
        try await collector.start()
        await gate.waitForArrival()
        // Use a separate caller so cancelling it never cancels the test itself.
        let refresh = Task {
            try await refreshAfterCancellation(collector, gate: gate, reenable: reenable, cancelCaller: cancelCaller)
        }
        let result = await refresh.result
        await collector.stop()
        let calls = await provider.calls
        let snapshot = try AtomicSnapshotReader(directory: directory).latest()
        if cancelCaller {
            guard case .failure(let error) = result, error is CancellationError else {
                XCTFail("A cancelled refresh caller must remain cancelled"); return
            }
            XCTAssertEqual(calls, 0)
            XCTAssertNil(snapshot)
        } else if !reenable {
            guard case .failure(StoreError.unavailable) = result else {
                XCTFail("Refresh must re-check that the provider remains disabled"); return
            }
            XCTAssertEqual(calls, 0)
            XCTAssertNil(snapshot)
        } else {
            try result.get()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(snapshot?.sourceSequence, 1)
        }
    }

    private func refreshAfterCancellation(_ collector: isolated Collector, gate: CancellationGate,
        reenable: Bool, cancelCaller: Bool) async throws {
        collector.setEnabled(false, key: "test/test_account")
        if reenable { collector.setEnabled(true, key: "test/test_account") }
        // This task inherits Collector isolation, so it cannot release the old
        // pass until refresh has entered and suspended waiting for that pass.
        Task { _ = collector.diagnostics(); await gate.open() }
        if cancelCaller { withUnsafeCurrentTask { $0?.cancel() } }
        try await collector.refresh()
    }
}
