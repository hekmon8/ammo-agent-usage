import Foundation
import CryptoKit
import QuotaCore
import QuotaStore

/// Stores only authenticated ciphertext. The caller must retrieve keys from protected storage.
public actor VerifiedUsageCache {
    public let directory: URL
    private let trust: SourceTrust
    public init(directory: URL, trust: SourceTrust) throws {
        try PrivateFile.prepareDirectory(directory)
        let binding = ["QI-USAGE-1", trust.workspaceID, trust.deviceID, trust.epoch, trust.keyID, Base64URL.encode(trust.publicKey)].joined(separator: "|")
        let namespace = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = directory.appendingPathComponent(namespace); self.trust = trust
        try PrivateFile.prepareDirectory(self.directory)
    }
    public func latest(key: SymmetricKey) throws -> TokenUsageSnapshot? {
        do { return try UsageEnvelopeCodec.open(PrivateFile.read(directory.appendingPathComponent("verified-usage-envelope.json"), maxBytes: 262_144), trust: trust, key: key) }
        catch StoreError.unavailable { return nil }
    }
    public func accept(_ data: Data, key: SymmetricKey) throws -> TokenUsageSnapshot {
        let transaction = try FileTransaction(directory: directory, name: "verified-usage-cache")
        defer { withExtendedLifetime(transaction) {} }
        let incoming = try UsageEnvelopeCodec.decode(data)
        let snapshot = try UsageEnvelopeCodec.open(data, trust: trust, key: key)
        let url = directory.appendingPathComponent("verified-usage-envelope.json")
        do {
            let oldData = try PrivateFile.read(url, maxBytes: 262_144)
            _ = try UsageEnvelopeCodec.open(oldData, trust: trust, key: key)
            let old = try UsageEnvelopeCodec.decode(oldData)
            guard incoming.sequence > old.sequence || (incoming.sequence == old.sequence && incoming.contentHash == old.contentHash) else { throw SyncError.replay }
        } catch StoreError.unavailable { /* First authenticated snapshot. */ }
        try PrivateFile.write(data, to: url)
        return snapshot
    }
}

public actor PendingUsageEnvelope {
    private let file: URL
    public init(directory: URL) throws { try PrivateFile.prepareDirectory(directory); file = directory.appendingPathComponent("pending-usage-envelope.json") }
    public func prepare(snapshot: TokenUsageSnapshot, workspaceID: String, keyID: String, key: SymmetricKey, signer: Curve25519.Signing.PrivateKey) throws -> Data {
        let transaction = try FileTransaction(directory: file.deletingLastPathComponent(), name: "pending-usage-envelope")
        defer { withExtendedLifetime(transaction) {} }
        do {
            let data = try PrivateFile.read(file, maxBytes: 262_144)
            let pending = try UsageEnvelopeCodec.decode(data)
            guard pending.workspaceId == workspaceID, pending.sourceDeviceId == snapshot.sourceDeviceId, pending.sourceEpoch == snapshot.sourceEpoch, pending.keyId == keyID else { throw SyncError.configuration }
            // Revoking local usage consent supersedes an older unsent aggregate.
            // Atomically replace only with a strictly newer disabled observation.
            if snapshot.isDisabledObservation {
                let trust = SourceTrust(workspaceID: workspaceID, deviceID: snapshot.sourceDeviceId,
                    epoch: snapshot.sourceEpoch, keyID: keyID, publicKey: signer.publicKey.rawRepresentation)
                let previous = try UsageEnvelopeCodec.open(data, trust: trust, key: key)
                if previous.isDisabledObservation { return data }
                guard pending.sequence < snapshot.sourceSequence else { throw SyncError.replay }
                let replacement = try UsageEnvelopeCodec.seal(snapshot, workspaceID: workspaceID, keyID: keyID, key: key, signingKey: signer)
                try PrivateFile.write(replacement, to: file)
                return replacement
            }
            return data
        } catch StoreError.unavailable {
            let data = try UsageEnvelopeCodec.seal(snapshot, workspaceID: workspaceID, keyID: keyID, key: key, signingKey: signer)
            try PrivateFile.write(data, to: file)
            return data
        }
    }
    /// Recover a crash after persisting the receipt but before removing pending bytes.
    public func discardAcknowledged(sequence: Int64, contentHash: String) throws {
        let transaction = try FileTransaction(directory: file.deletingLastPathComponent(), name: "pending-usage-envelope")
        defer { withExtendedLifetime(transaction) {} }
        do {
            let existing = try UsageEnvelopeCodec.decode(PrivateFile.read(file, maxBytes: 262_144))
            if existing.sequence <= sequence {
                guard existing.sequence == sequence, existing.contentHash == contentHash else { throw SyncError.replay }
                try FileManager.default.removeItem(at: file)
            }
        } catch StoreError.unavailable { /* Already removed. */ }
    }
    public func acknowledge(contentHash: String) throws {
        let transaction = try FileTransaction(directory: file.deletingLastPathComponent(), name: "pending-usage-envelope")
        defer { withExtendedLifetime(transaction) {} }
        let existing = try UsageEnvelopeCodec.decode(PrivateFile.read(file, maxBytes: 262_144))
        guard existing.contentHash == contentHash else { throw SyncError.replay }
        // Only delete this owned, acknowledged pending ciphertext, never account or user data.
        try FileManager.default.removeItem(at: file)
    }
}
