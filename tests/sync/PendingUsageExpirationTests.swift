import CryptoKit
import Foundation
import XCTest
import QuotaCore
@testable import QuotaStore
@testable import QuotaSync

final class PendingUsageExpirationTests: XCTestCase {
    private final class FailMutation: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func reject() throws {
            lock.lock(); attempts += 1; lock.unlock()
            throw StoreError.unavailable
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    }

    private func snapshot(_ sequence: Int64, disabled: Bool) -> TokenUsageSnapshot {
        TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: sequence,
            capturedAt: "2026-10-15T08:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-01",
            sources: [TokenUsageSource(agent: .codex, status: disabled ? .disabled : .available)], buckets: [])
    }

    func testExpiredDisabledReplacementDoesNotFallBackToMissingFileOrRetryMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try PendingUsageEnvelope(directory: root)
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let existing = try await pending.prepare(snapshot: snapshot(1, disabled: false), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        let disabled = snapshot(2, disabled: true)
        let failure = FailMutation()
        do {
            _ = try await FileTransactionProtectionProvider.$override.withValue({ FileTransactionProtection.checkingMutations(failure.reject) }) {
                try await pending.prepare(snapshot: disabled, workspaceID: "ws", keyID: "key", key: key, signer: signer)
            }
            XCTFail("Expired replacement was reported as successful")
        } catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        XCTAssertEqual(failure.count, 1, "An expired mutation must not trigger a second missing-file attempt")
        XCTAssertEqual(try PrivateFile.read(root.appendingPathComponent("pending-usage-envelope.json"), maxBytes: 262_144), existing)
    }

    func testExpiredAcknowledgedDeletionPropagatesFailureAndPreservesPendingBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try PendingUsageEnvelope(directory: root)
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let existing = try await pending.prepare(snapshot: snapshot(1, disabled: false), workspaceID: "ws", keyID: "key", key: key, signer: signer)
        let envelope = try UsageEnvelopeCodec.decode(existing)
        let failure = FailMutation()
        do {
            try await FileTransactionProtectionProvider.$override.withValue({ FileTransactionProtection.checkingMutations(failure.reject) }) {
                try await pending.discardAcknowledged(sequence: envelope.sequence, contentHash: envelope.contentHash)
            }
            XCTFail("Expiration was incorrectly treated as an already removed file")
        } catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(try PrivateFile.read(root.appendingPathComponent("pending-usage-envelope.json"), maxBytes: 262_144), existing)
    }
}
