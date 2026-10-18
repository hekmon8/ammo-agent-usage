import Foundation
import CryptoKit
import QuotaCore

/// Usage sidecar envelopes have their own AAD/signature domain. Never decode a
/// usage payload with the legacy quota codec or accept a quota envelope here.
public enum UsageEnvelopeCodec {
    private static func header(_ e: EncryptedEnvelope) -> Data { Data("QI-USAGE|1|\(e.workspaceId)|\(e.sourceDeviceId)|\(e.sourceEpoch)|\(e.sequence)|\(e.keyId)".utf8) }
    private static func message(_ e: EncryptedEnvelope) throws -> Data { try header(e) + Data([10]) + Base64URL.decode(e.nonce) + Base64URL.decode(e.ciphertext) + Base64URL.decode(e.tag) }
    public static func decode(_ data: Data) throws -> EncryptedEnvelope {
        // A sealed 128 KiB snapshot base64-encodes to ~176 KB of envelope JSON.
        guard data.count <= 262_144, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion","workspaceId","sourceDeviceId","sourceEpoch","sequence","keyId","nonce","ciphertext","tag","signature","contentHash"]) else { throw SyncError.invalidEnvelope }
        let e = try JSONDecoder().decode(EncryptedEnvelope.self, from: data)
        guard e.schemaVersion == "1.0.0", e.sequence > 0, e.sequence <= 9_007_199_254_740_991,
              [e.workspaceId, e.sourceDeviceId, e.sourceEpoch, e.keyId].allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }),
              e.ciphertext.count <= 174_763, try Base64URL.decode(e.ciphertext).count <= 131_072,
              try Base64URL.decode(e.nonce).count == 12, try Base64URL.decode(e.tag).count == 16, try Base64URL.decode(e.signature).count == 64,
              e.contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError.invalidEnvelope }
        return e
    }
    public static func seal(_ snapshot: TokenUsageSnapshot, workspaceID: String, keyID: String, key: SymmetricKey, signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        guard key.bitCount == 256 else { throw SyncError.invalidKey }
        let prototype = EncryptedEnvelope(schemaVersion: "1.0.0", workspaceId: workspaceID, sourceDeviceId: snapshot.sourceDeviceId, sourceEpoch: snapshot.sourceEpoch, sequence: snapshot.sourceSequence, keyId: keyID, nonce: "", ciphertext: "", tag: "", signature: "", contentHash: "")
        let sealed = try AES.GCM.seal(TokenUsageSnapshotCodec.encode(snapshot), using: key, authenticating: header(prototype))
        let unsigned = EncryptedEnvelope(schemaVersion: prototype.schemaVersion, workspaceId: workspaceID, sourceDeviceId: snapshot.sourceDeviceId, sourceEpoch: snapshot.sourceEpoch, sequence: snapshot.sourceSequence, keyId: keyID, nonce: Base64URL.encode(Data(sealed.nonce)), ciphertext: Base64URL.encode(sealed.ciphertext), tag: Base64URL.encode(sealed.tag), signature: "", contentHash: "")
        let bytes = try message(unsigned)
        let envelope = EncryptedEnvelope(schemaVersion: unsigned.schemaVersion, workspaceId: unsigned.workspaceId, sourceDeviceId: unsigned.sourceDeviceId, sourceEpoch: unsigned.sourceEpoch, sequence: unsigned.sequence, keyId: unsigned.keyId, nonce: unsigned.nonce, ciphertext: unsigned.ciphertext, tag: unsigned.tag, signature: Base64URL.encode(try signingKey.signature(for: bytes)), contentHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let data = try JSONEncoder().encode(envelope); _ = try decode(data); return data
    }
    public static func open(_ data: Data, trust: SourceTrust, key: SymmetricKey) throws -> TokenUsageSnapshot {
        let envelope = try decode(data)
        guard key.bitCount == 256, envelope.workspaceId == trust.workspaceID, envelope.sourceDeviceId == trust.deviceID, envelope.sourceEpoch == trust.epoch, envelope.keyId == trust.keyID else { throw SyncError.untrustedSource }
        let bytes = try message(envelope)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: trust.publicKey).isValidSignature(Base64URL.decode(envelope.signature), for: bytes),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == envelope.contentHash else { throw SyncError.untrustedSource }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Base64URL.decode(envelope.nonce)), ciphertext: Base64URL.decode(envelope.ciphertext), tag: Base64URL.decode(envelope.tag))
        let snapshot = try TokenUsageSnapshotCodec.decode(AES.GCM.open(sealed, using: key, authenticating: header(envelope)))
        guard snapshot.sourceDeviceId == trust.deviceID, snapshot.sourceEpoch == trust.epoch, snapshot.sourceSequence == envelope.sequence else { throw SyncError.untrustedSource }
        return snapshot
    }
}
