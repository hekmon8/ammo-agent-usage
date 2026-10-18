import XCTest
import Foundation
@testable import QuotaSync

final class BootstrapRecoveryTests: XCTestCase {
    private final class MemoryVault: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var writerLocked = false
        private var lockedRemoval: String?
        func setWriterLocked(_ locked: Bool) { lock.lock(); defer { lock.unlock() }; writerLocked = locked }
        func setLockedRemoval(_ account: String?) { lock.lock(); defer { lock.unlock() }; lockedRemoval = account }
        func load(_ account: String) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = values[account] else { throw VaultError.unavailable }
            return data
        }
        func save(_ data: Data, account: String) throws {
            lock.lock(); defer { lock.unlock() }
            if account == "writer" && writerLocked { throw VaultError.locked }
            values[account] = data
        }
        func remove(_ account: String) throws {
            lock.lock(); defer { lock.unlock() }
            if lockedRemoval == account { throw VaultError.locked }
            values.removeValue(forKey: account)
        }
    }

    private let endpoint = URL(string: "https://quota.example.invalid")!
    private func successfulTransport() throws -> SyncTransport {
        try SyncTransport(baseURL: endpoint) { request in
            (Data(#"{"workspaceId":"initial-workspace","deviceId":"mac-test","deviceToken":"synthetic-issued-token","sourceEpoch":"initial-epoch"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testLaunchRecoversSavedFirstConnectionReceiptWithoutTokenEntryOrNetwork() async throws {
        let vault = MemoryVault()
        vault.setWriterLocked(true)
        do {
            _ = try await SyncWriter.bootstrap(endpoint: endpoint, token: "synthetic-bootstrap", vault: vault, transport: successfulTransport())
            XCTFail("Writer save should fail after receipt persistence")
        } catch VaultError.locked {}
        let draftData = try vault.load("bootstrap-draft")
        let receiptData = try vault.load("bootstrap-response")
        XCTAssertFalse(receiptData.isEmpty)
        XCTAssertFalse(try vault.contains("writer"))
        XCTAssertNil(try SyncWriter.pendingReplacementBootstrap(vault: vault))
        let offline = try SyncTransport(baseURL: endpoint) { _ in throw TransportError.unavailable }
        // A failed recovery must keep the only durable copy of the identity.
        do { _ = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline); XCTFail("Locked writer accepted") }
        catch VaultError.locked {}
        XCTAssertEqual(try vault.load("bootstrap-draft"), draftData)
        XCTAssertEqual(try vault.load("bootstrap-response"), receiptData)
        vault.setWriterLocked(false)
        let recovered = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        let credentials = try XCTUnwrap(recovered)
        let draft = try XCTUnwrap(JSONSerialization.jsonObject(with: draftData) as? [String: Any])
        XCTAssertEqual(credentials.workspaceID, "initial-workspace")
        XCTAssertEqual(credentials.token, "synthetic-issued-token")
        XCTAssertEqual(credentials.signingPrivateKey.base64EncodedString(), draft["signingKey"] as? String)
        XCTAssertEqual(credentials.snapshotKey.base64EncodedString(), draft["snapshotKey"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer")).token, credentials.token)
        XCTAssertFalse(try vault.contains("bootstrap-draft"))
        XCTAssertFalse(try vault.contains("bootstrap-response"))
        let again = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        XCTAssertNil(again)
    }

    func testLaunchRecoveryDoesNotConsumeReplacementDraftOrOverwriteAnExistingWriter() async throws {
        let vault = MemoryVault()
        let target = try await SyncWriter.bootstrap(endpoint: endpoint, token: "synthetic-bootstrap", vault: vault,
            transport: successfulTransport(), supersedingStored: true, persist: false)
        let draft = try vault.load("bootstrap-draft")
        let receipt = try vault.load("bootstrap-response")
        let offline = try SyncTransport(baseURL: endpoint) { _ in throw TransportError.unavailable }
        let recovered = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        XCTAssertNil(recovered)
        XCTAssertEqual(try vault.load("bootstrap-draft"), draft)
        XCTAssertEqual(try vault.load("bootstrap-response"), receipt)
        XCTAssertFalse(try vault.contains("writer"))
        let existing = try JSONEncoder().encode(target)
        try vault.save(existing, account: "writer")
        let withWriter = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        XCTAssertNil(withWriter)
        XCTAssertEqual(try vault.load("writer"), existing)
        XCTAssertEqual(try vault.load("bootstrap-draft"), draft)
    }

    func testLaunchCompletesMatchingWriterCleanupWithoutReissuingIdentity() async throws {
        let vault = MemoryVault()
        vault.setLockedRemoval("bootstrap-draft")
        do {
            _ = try await SyncWriter.bootstrap(endpoint: endpoint, token: "synthetic-bootstrap", vault: vault, transport: successfulTransport())
            XCTFail("Expected interrupted cleanup after writer commit")
        } catch VaultError.locked {}
        let writer = try vault.load("writer")
        let draft = try vault.load("bootstrap-draft")
        XCTAssertFalse(try vault.contains("bootstrap-response"), "Remove the receipt before the recovery marker")
        let offline = try SyncTransport(baseURL: endpoint) { _ in throw TransportError.unavailable }
        do { _ = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline); XCTFail("Cleanup lock ignored") }
        catch VaultError.locked {}
        XCTAssertEqual(try vault.load("writer"), writer)
        XCTAssertEqual(try vault.load("bootstrap-draft"), draft)
        vault.setLockedRemoval(nil)
        let recovered = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        XCTAssertEqual(try XCTUnwrap(recovered).token, "synthetic-issued-token")
        XCTAssertEqual(try vault.load("writer"), writer)
        XCTAssertFalse(try vault.contains("bootstrap-draft"))
    }

    func testInitialDraftCannotCleanUpOrReplaceDifferentExistingIdentity() async throws {
        let vault = MemoryVault()
        let pending = try await SyncWriter.bootstrap(endpoint: endpoint, token: "synthetic-bootstrap", vault: vault,
            transport: successfulTransport(), persist: false)
        let unrelated = WriterCredentials(endpoint: endpoint, workspaceID: "different-workspace", deviceID: "different-device",
            epoch: "different-epoch", token: "different-token", keyID: pending.keyID,
            signingPrivateKey: Data(repeating: 1, count: 32), snapshotKey: pending.snapshotKey)
        let stored = try JSONEncoder().encode(unrelated)
        try vault.save(stored, account: "writer")
        let draft = try vault.load("bootstrap-draft"), receipt = try vault.load("bootstrap-response")
        let offline = try SyncTransport(baseURL: endpoint) { _ in throw TransportError.unavailable }
        let recovered = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: offline)
        XCTAssertNil(recovered)
        XCTAssertEqual(try vault.load("writer"), stored)
        XCTAssertEqual(try vault.load("bootstrap-draft"), draft)
        XCTAssertEqual(try vault.load("bootstrap-response"), receipt)
    }
}
