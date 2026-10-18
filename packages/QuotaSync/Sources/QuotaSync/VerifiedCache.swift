import Foundation
import CryptoKit
import QuotaCore
import QuotaStore

/// Stores only authenticated ciphertext. The caller must retrieve keys from protected storage.
public actor VerifiedCache {
    public let directory: URL
    private let trust: SourceTrust
    public init(directory: URL, trust: SourceTrust) throws {
        try PrivateFile.prepareDirectory(directory)
        let binding = [trust.workspaceID, trust.deviceID, trust.epoch, trust.keyID, Base64URL.encode(trust.publicKey)].joined(separator: "|")
        let namespace = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = directory.appendingPathComponent(namespace); self.trust = trust
        try PrivateFile.prepareDirectory(self.directory)
    }
    public func latest(key: SymmetricKey) throws -> Snapshot? {
        do { return try EnvelopeCodec.open(PrivateFile.read(directory.appendingPathComponent("verified-envelope.json"), maxBytes: 262_144), trust: trust, key: key) }
        catch StoreError.unavailable { return nil }
    }
    public func accept(_ data: Data, key: SymmetricKey) throws -> Snapshot {
        let transaction = try FileTransaction(directory: directory, name: "verified-cache")
        defer { withExtendedLifetime(transaction) {} }
        let incoming = try EnvelopeCodec.decode(data)
        let snapshot = try EnvelopeCodec.open(data, trust: trust, key: key)
        let url = directory.appendingPathComponent("verified-envelope.json")
        do {
            let oldData = try PrivateFile.read(url, maxBytes: 262_144)
            _ = try EnvelopeCodec.open(oldData, trust: trust, key: key)
            let old = try EnvelopeCodec.decode(oldData)
            guard incoming.sequence > old.sequence || (incoming.sequence == old.sequence && incoming.contentHash == old.contentHash) else { throw SyncError.replay }
        } catch StoreError.unavailable { /* First authenticated snapshot. */ }
        try PrivateFile.write(data, to: url)
        return snapshot
    }
}

public actor PendingEnvelope {
    private let file: URL
    public init(directory: URL) throws { try PrivateFile.prepareDirectory(directory); file = directory.appendingPathComponent("pending-envelope.json") }
    public func prepare(snapshot: Snapshot, workspaceID: String, keyID: String, key: SymmetricKey, signer: Curve25519.Signing.PrivateKey) throws -> Data {
        let transaction = try FileTransaction(directory: file.deletingLastPathComponent(), name: "pending-envelope")
        defer { withExtendedLifetime(transaction) {} }
        do {
            let data = try PrivateFile.read(file, maxBytes: 262_144)
            let pending = try EnvelopeCodec.decode(data)
            guard pending.workspaceId == workspaceID, pending.sourceDeviceId == snapshot.sourceDeviceId, pending.sourceEpoch == snapshot.sourceEpoch, pending.keyId == keyID else { throw SyncError.configuration }
            return data
        } catch StoreError.unavailable {
            let data = try EnvelopeCodec.seal(snapshot, workspaceID: workspaceID, keyID: keyID, key: key, signingKey: signer)
            try PrivateFile.write(data, to: file)
            return data
        }
    }
    public func acknowledge(contentHash: String) throws {
        let transaction = try FileTransaction(directory: file.deletingLastPathComponent(), name: "pending-envelope")
        defer { withExtendedLifetime(transaction) {} }
        let existing = try EnvelopeCodec.decode(PrivateFile.read(file, maxBytes: 262_144))
        guard existing.contentHash == contentHash else { throw SyncError.replay }
        // Only delete this owned, acknowledged pending ciphertext, never account or user data.
        try FileManager.default.removeItem(at: file)
    }
}
