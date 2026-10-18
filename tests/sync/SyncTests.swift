import Foundation
import XCTest
import CryptoKit
import QuotaCore
import QuotaStore
@testable import QuotaSync

final class SyncTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func testExistingCrossLanguageGoldenAndTamperRejection() throws {
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/examples/crypto-golden-vector.TEST-ONLY.json"))) as! [String: String]
        let envelope = try Data(contentsOf: root.appendingPathComponent("contracts/examples/envelope.example.json"))
        let trust = SourceTrust(workspaceID: "ws_demo", deviceID: "mac_demo", epoch: "epoch_demo", keyID: "key_demo_v1", publicKey: try Base64URL.decode(vector["sourceSigningPublicKeyBase64url"]!))
        let key = SymmetricKey(data: try Base64URL.decode(vector["aesKeyBase64url"]!))
        XCTAssertEqual(try EnvelopeCodec.open(envelope, trust: trust, key: key).windows[0].remainingBps, 6800)
        for field in ["ciphertext", "tag", "signature", "sourceEpoch", "workspaceId", "contentHash"] {
            var changed = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
            let old = changed[field] as! String
            changed[field] = (old.hasPrefix("a") ? "b" : "a") + old.dropFirst()
            XCTAssertThrowsError(try EnvelopeCodec.open(JSONSerialization.data(withJSONObject: changed), trust: trust, key: key), field)
        }
    }
    func testHPKEWrapBindsRecipientContextAndPinnedSource() throws {
        let source = Curve25519.Signing.PrivateKey(), recipient = Curve25519.KeyAgreement.PrivateKey(), key = SymmetricKey(size: .bits256)
        let context = "workspace|mac|epoch|key|claim"
        let wrapped = try SnapshotKeyWrap.seal(key: key, recipient: recipient.publicKey, context: context, signer: source)
        let opened = try SnapshotKeyWrap.open(wrapped, recipient: recipient, context: context, sourceKey: source.publicKey)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, opened.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try SnapshotKeyWrap.open(wrapped, recipient: recipient, context: "workspace|mac|epoch|key|other", sourceKey: source.publicKey))
        XCTAssertThrowsError(try SnapshotKeyWrap.open(wrapped, recipient: Curve25519.KeyAgreement.PrivateKey(), context: context, sourceKey: source.publicKey))
        XCTAssertThrowsError(try SnapshotKeyWrap.open(wrapped, recipient: recipient, context: context, sourceKey: Curve25519.Signing.PrivateKey().publicKey))
    }
    func testPendingRetryIsByteIdenticalAndBadCacheUpdatePreservesLastGood() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let snapshot = try SnapshotCodec.decode(Data(contentsOf: root.appendingPathComponent("contracts/fixtures/01-fresh.json")))
        let pending = try PendingEnvelope(directory: directory)
        let first = try await pending.prepare(snapshot: snapshot, workspaceID: "ws_demo", keyID: "key_demo", key: key, signer: source)
        let second = try await pending.prepare(snapshot: snapshot, workspaceID: "ws_demo", keyID: "key_demo", key: key, signer: source)
        XCTAssertEqual(first, second)
        let trust = SourceTrust(workspaceID: "ws_demo", deviceID: snapshot.sourceDeviceId, epoch: snapshot.sourceEpoch, keyID: "key_demo", publicKey: source.publicKey.rawRepresentation)
        let cache = try VerifiedCache(directory: directory, trust: trust)
        _ = try await cache.accept(first, key: key)
        do { _ = try await cache.accept(Data("bad-json".utf8), key: key); XCTFail("accepted invalid cache") } catch {}
        let good = try await cache.latest(key: key)
        XCTAssertEqual(good?.sourceSequence, 42)
        let conflict = try EnvelopeCodec.seal(snapshot, workspaceID: "ws_demo", keyID: "key_demo", key: key, signingKey: source)
        do { _ = try await cache.accept(conflict, key: key); XCTFail("accepted same-sequence different envelope") } catch SyncError.replay {}
    }
}
