import Foundation
import CryptoKit
import QuotaCore
import QuotaStore

public struct WriterCredentials: Codable, Sendable {
    public let endpoint: URL
    public let workspaceID, deviceID, epoch, token, keyID: String
    public let signingPrivateKey, snapshotKey: Data
}
/// A single old service retained after the user explicitly elects to use a
/// replacement before remote revocation can be confirmed.
public struct RetiredServiceRevocation: Codable, Sendable {
    public let credentials: WriterCredentials
    private static let account = "retired-service-revocation"

    public init(credentials: WriterCredentials) { self.credentials = credentials }
    public static func pending(vault: any SecretStoring) throws -> Self? {
        let data: Data
        do { data = try vault.load(account) }
        catch VaultError.unavailable { return nil }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public static func retain(_ credentials: WriterCredentials, vault: any SecretStoring) throws {
        try vault.insert(JSONEncoder().encode(Self(credentials: credentials)), account: account)
    }
    public static func clear(vault: any SecretStoring) throws { try vault.remove(account) }
    public func matches(_ other: WriterCredentials) -> Bool {
        credentials.endpoint == other.endpoint && credentials.workspaceID == other.workspaceID &&
            credentials.deviceID == other.deviceID && credentials.epoch == other.epoch &&
            credentials.token == other.token
    }
}
public struct WriterClaim: Decodable, Sendable {
    public let state: String
    public let claimId, deviceName, recipientPublicKey: String?
    public let expiresAt: String
}
public actor SyncWriter {
    private let credentials: WriterCredentials
    private let pending: PendingEnvelope
    private let pendingUsage: PendingUsageEnvelope
    private let directory: URL
    private let transport: SyncTransport
    private var paused = false
    private var syncEnabled = true
    private var active: (id: UUID, task: Task<Void, Error>)?
    private var activeUsage: (id: UUID, task: Task<Bool, Error>)?
    public init(credentials: WriterCredentials, directory: URL, transport: SyncTransport? = nil) throws {
        let namespace = SHA256.hash(data: Data([credentials.workspaceID,credentials.deviceID,credentials.epoch,credentials.keyID].joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = directory.appendingPathComponent(namespace)
        self.credentials = credentials; pending = try PendingEnvelope(directory: self.directory)
        pendingUsage = try PendingUsageEnvelope(directory: self.directory)
        self.transport = try transport ?? SyncTransport(baseURL: credentials.endpoint)
    }

    private struct BootstrapDraft: Codable {
        let endpoint: URL
        let requestID, keyID: String
        let signingKey, snapshotKey: Data
        let bootstrapToken: String?
        let replacesWriter: Bool?
    }
    private struct BootstrapReceipt: Codable {
        let endpoint: URL
        let requestID: String
        let response: Data
    }
    public struct PendingReplacementBootstrap: Sendable, Equatable {
        public let endpoint: URL
        public let token: String
    }
    public static func pendingReplacementBootstrap(vault: any SecretStoring) throws -> PendingReplacementBootstrap? {
        let data: Data
        do { data = try vault.load("bootstrap-draft") }
        catch VaultError.unavailable { return nil }
        let draft = try JSONDecoder().decode(BootstrapDraft.self, from: data)
        guard draft.replacesWriter == true, let token = draft.bootstrapToken, !token.isEmpty else { return nil }
        return PendingReplacementBootstrap(endpoint: draft.endpoint, token: token)
    }
    /// Resume an explicitly requested first connection after interruption. A
    /// saved response is consumed offline; ambiguous requests reuse the draft.
    /// Only the same initial identity may finish interrupted local cleanup;
    /// unrelated writers and service replacements have their own restore paths.
    public static func recoverInitialBootstrap(vault: any SecretStoring, transport: SyncTransport? = nil) async throws -> WriterCredentials? {
        let data: Data
        do { data = try vault.load("bootstrap-draft") }
        catch VaultError.unavailable { return nil }
        let draft = try JSONDecoder().decode(BootstrapDraft.self, from: data)
        guard draft.replacesWriter != true, let token = draft.bootstrapToken, !token.isEmpty else { return nil }
        if try vault.contains("writer") {
            let existing = try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer"))
            guard existing.endpoint == draft.endpoint, existing.keyID == draft.keyID,
                  existing.signingPrivateKey == draft.signingKey, existing.snapshotKey == draft.snapshotKey else { return nil }
            try clearBootstrapRecovery(vault: vault)
            return existing
        }
        return try await bootstrap(endpoint: draft.endpoint, token: token, vault: vault, transport: transport)
    }
    /// With `supersedingStored`, an identity saved for another deployment is
    /// overwritten only after the new bootstrap succeeds, so a failed service
    /// switch leaves the previous credentials untouched.
    public static func bootstrap(endpoint: URL, token: String, vault: any SecretStoring, transport supplied: SyncTransport? = nil, supersedingStored: Bool = false, persist: Bool = true) async throws -> WriterCredentials {
        let transport = try supplied ?? SyncTransport(baseURL: endpoint)
        if !supersedingStored, let stored = try? vault.load("writer") {
            guard try pendingReplacementBootstrap(vault: vault) == nil else { throw SyncError.configuration }
            let existing = try JSONDecoder().decode(WriterCredentials.self, from: stored)
            guard existing.endpoint == endpoint else { throw SyncError.configuration }
            try clearBootstrapRecovery(vault: vault)
            return existing
        }
        var draft: BootstrapDraft
        do {
            draft = try JSONDecoder().decode(BootstrapDraft.self, from: vault.load("bootstrap-draft"))
            if draft.endpoint != endpoint || (draft.replacesWriter ?? false) != supersedingStored || (draft.bootstrapToken != nil && !token.isEmpty && draft.bootstrapToken != token) {
                draft = try Self.makeBootstrapDraft(endpoint, token: token, replacesWriter: supersedingStored, vault: vault)
            } else if draft.bootstrapToken == nil && !token.isEmpty {
                draft = BootstrapDraft(endpoint: draft.endpoint, requestID: draft.requestID, keyID: draft.keyID,
                    signingKey: draft.signingKey, snapshotKey: draft.snapshotKey, bootstrapToken: token,
                    replacesWriter: supersedingStored)
                try vault.save(JSONEncoder().encode(draft), account: "bootstrap-draft")
            }
        } catch VaultError.unavailable {
            draft = try Self.makeBootstrapDraft(endpoint, token: token, replacesWriter: supersedingStored, vault: vault)
        }
        guard let bootstrapToken = draft.bootstrapToken, !bootstrapToken.isEmpty else { throw SyncError.configuration }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: draft.signingKey)
        let data: Data
        if let stored = try? vault.load("bootstrap-response"),
           let receipt = try? JSONDecoder().decode(BootstrapReceipt.self, from: stored),
           receipt.endpoint == endpoint && receipt.requestID == draft.requestID {
            data = receipt.response
        } else {
            do { try vault.remove("bootstrap-response") }
            catch VaultError.unavailable { /* No previous receipt. */ }
            let (response, _) = try await transport.request(path: "/v1/bootstrap", method: "POST", token: bootstrapToken,
                body: JSONSerialization.data(withJSONObject: ["requestId": draft.requestID, "deviceName": "Mac", "sourcePublicKey": Base64URL.encode(signer.publicKey.rawRepresentation)]), bootstrap: true)
            // Save provider-generated credentials immediately on first receipt.
            try vault.save(JSONEncoder().encode(BootstrapReceipt(endpoint: endpoint, requestID: draft.requestID, response: response)), account: "bootstrap-response")
            data = response
        }
        struct Result: Decodable { let workspaceId, deviceId, deviceToken, sourceEpoch: String }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: result.workspaceId, deviceID: result.deviceId, epoch: result.sourceEpoch,
            token: result.deviceToken, keyID: draft.keyID, signingPrivateKey: draft.signingKey, snapshotKey: draft.snapshotKey)
        if persist {
            try commitBootstrap(credentials, vault: vault)
        }
        return credentials
    }
    /// Commit only after a replacement service has been prepared and the old
    /// service's grants have been revoked. A failed commit leaves the draft for retry.
    public static func commitBootstrap(_ credentials: WriterCredentials, vault: any SecretStoring) throws {
        try vault.save(JSONEncoder().encode(credentials), account: "writer")
        try clearBootstrapRecovery(vault: vault)
    }
    public static func clearBootstrapRecovery(vault: any SecretStoring) throws {
        try vault.remove("bootstrap-response")
        try vault.remove("bootstrap-draft")
    }
    /// A received bootstrap response may hold the only copy of a newly issued
    /// writer token, so it must be recovered rather than discarded.
    public static func canCancelPendingReplacementBootstrap(vault: any SecretStoring) throws -> Bool {
        guard try !vault.contains("switch-target"), try !vault.contains("bootstrap-response") else { return false }
        return try pendingReplacementBootstrap(vault: vault) != nil
    }
    public static func cancelPendingReplacementBootstrap(vault: any SecretStoring) throws {
        guard try canCancelPendingReplacementBootstrap(vault: vault) else { throw SyncError.configuration }
        try clearBootstrapRecovery(vault: vault)
    }
    private static func makeBootstrapDraft(_ endpoint: URL, token: String, replacesWriter: Bool, vault: any SecretStoring) throws -> BootstrapDraft {
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let draft = BootstrapDraft(endpoint: endpoint, requestID: UUID().uuidString, keyID: "key-" + UUID().uuidString,
            signingKey: signer.rawRepresentation, snapshotKey: key.withUnsafeBytes { Data($0) },
            bootstrapToken: token, replacesWriter: replacesWriter)
        try vault.save(JSONEncoder().encode(draft), account: "bootstrap-draft")
        return draft
    }
    public func setSyncEnabled(_ enabled: Bool) async {
        syncEnabled = enabled
        if !enabled {
            active?.task.cancel()
            activeUsage?.task.cancel()
            _ = try? await active?.task.value
            _ = try? await activeUsage?.task.value
        }
    }
    public func pauseForRotation() async { paused = true; _ = try? await active?.task.value; _ = try? await activeUsage?.task.value }
    public func upload(_ local: Snapshot) async throws {
        guard !paused, syncEnabled else { throw SyncError.unavailable }
        if let previous = active {
            try await previous.task.value
            if active?.id == previous.id { active = nil }
            return try await upload(local)
        }
        let id = UUID()
        let task = Task { try await self.performUpload(local) }; active = (id, task)
        defer { if active?.id == id { active = nil } }; try await task.value
    }
    private struct SavedReceipt: Codable { let epoch, contentHash: String; let sourceSequence: Int64 }
    private func performUpload(_ local: Snapshot) async throws {
        guard syncEnabled else { throw SyncError.unavailable }
        try Task.checkCancellation()
        let receiptFile = directory.appendingPathComponent("last-receipt.json")
        if let bytes = try? PrivateFile.read(receiptFile, maxBytes: 4096), let saved = try? JSONDecoder().decode(SavedReceipt.self, from: bytes),
           saved.epoch == credentials.epoch, saved.sourceSequence >= local.sourceSequence { return }

        let snapshot = try Snapshot.make(windows: local.windows, deviceID: credentials.deviceID, epoch: credentials.epoch, sequence: local.sourceSequence, capturedAt: QuotaRules.date(local.capturedAt)!)
        let data = try await pending.prepare(snapshot: snapshot, workspaceID: credentials.workspaceID, keyID: credentials.keyID,
            key: SymmetricKey(data: credentials.snapshotKey), signer: Curve25519.Signing.PrivateKey(rawRepresentation: credentials.signingPrivateKey))
        let envelope = try EnvelopeCodec.decode(data)
        guard syncEnabled else { throw SyncError.unavailable }
        try Task.checkCancellation()
        let (reply, _) = try await transport.request(path: "/v1/snapshot", method: "PUT", token: credentials.token, body: data)
        struct Receipt: Decodable { let contentHash: String; let sourceSequence: Int64 }
        let receipt = try JSONDecoder().decode(Receipt.self, from: reply)
        guard receipt.contentHash == envelope.contentHash, receipt.sourceSequence == envelope.sequence else { throw SyncError.replay }
        try PrivateFile.write(JSONEncoder().encode(SavedReceipt(epoch: credentials.epoch, contentHash: receipt.contentHash, sourceSequence: receipt.sourceSequence)), to: receiptFile)
        try await pending.acknowledge(contentHash: receipt.contentHash)
        if envelope.sequence < local.sourceSequence { try await performUpload(local) }
    }
    /// Upload an independent cumulative aggregate. False means an older Worker
    /// does not support the sidecar; callers must keep quota sync independent.
    @discardableResult
    public func uploadUsage(_ local: TokenUsageSnapshot) async throws -> Bool {
        guard !paused, syncEnabled else { throw SyncError.unavailable }
        if let previous = activeUsage {
            _ = try await previous.task.value
            if activeUsage?.id == previous.id { activeUsage = nil }
            return try await uploadUsage(local)
        }
        let id = UUID()
        let task = Task { try await self.performUsageUpload(local) }; activeUsage = (id, task)
        defer { if activeUsage?.id == id { activeUsage = nil } }
        return try await task.value
    }
    private func performUsageUpload(_ local: TokenUsageSnapshot) async throws -> Bool {
        guard syncEnabled else { throw SyncError.unavailable }
        try Task.checkCancellation()
        let receiptFile = directory.appendingPathComponent("last-usage-receipt.json")
        if let bytes = try? PrivateFile.read(receiptFile, maxBytes: 4096),
           let saved = try? JSONDecoder().decode(SavedReceipt.self, from: bytes), saved.epoch == credentials.epoch {
            try await pendingUsage.discardAcknowledged(sequence: saved.sourceSequence, contentHash: saved.contentHash)
            if saved.sourceSequence >= local.sourceSequence { return true }
        }
        let snapshot = local.rebased(deviceID: credentials.deviceID, epoch: credentials.epoch, sequence: local.sourceSequence)
        let data = try await pendingUsage.prepare(snapshot: snapshot, workspaceID: credentials.workspaceID, keyID: credentials.keyID,
            key: SymmetricKey(data: credentials.snapshotKey), signer: Curve25519.Signing.PrivateKey(rawRepresentation: credentials.signingPrivateKey))
        let envelope = try UsageEnvelopeCodec.decode(data)
        guard syncEnabled else { throw SyncError.unavailable }
        try Task.checkCancellation()
        let reply: Data
        do {
            let (body, response) = try await transport.request(path: "/v1/usage", method: "PUT", token: credentials.token, body: data)
            if response.statusCode == 404 || response.statusCode == 405 { return false }
            guard (200..<300).contains(response.statusCode) else { throw TransportError.rejected(response.statusCode) }
            reply = body
        } catch TransportError.rejected(let status) where status == 404 || status == 405 { return false }
        struct Receipt: Decodable { let contentHash: String; let sourceSequence: Int64 }
        let receipt = try JSONDecoder().decode(Receipt.self, from: reply)
        guard receipt.contentHash == envelope.contentHash, receipt.sourceSequence == envelope.sequence else { throw SyncError.replay }
        try PrivateFile.write(JSONEncoder().encode(SavedReceipt(epoch: credentials.epoch, contentHash: receipt.contentHash, sourceSequence: receipt.sourceSequence)), to: receiptFile)
        try await pendingUsage.acknowledge(contentHash: receipt.contentHash)
        if envelope.sequence < local.sourceSequence { return try await performUsageUpload(local) }
        return true
    }
    public func createInvitation() async throws -> PairingInvitation {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Worker hashes the textual bearer secret, not decoded random bytes.
        let encodedSecret = Base64URL.encode(secret)
        let textHash = SHA256.hash(data: Data(encodedSecret.utf8)).map { String(format: "%02x", $0) }.joined()
        let (data, _) = try await transport.request(path: "/v1/pairings", method: "POST", token: credentials.token,
            body: JSONSerialization.data(withJSONObject: ["pairingSecretHash": textHash]))
        struct Result: Decodable { let pairingId: String }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return PairingInvitation(endpoint: credentials.endpoint, pairingId: result.pairingId, secret: encodedSecret,
            sourcePublicKey: Base64URL.encode(try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.signingPrivateKey).publicKey.rawRepresentation))
    }
    public func inspect(pairingID: String) async throws -> WriterClaim {
        guard pairingID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw SyncError.configuration }
        let (data, _) = try await transport.request(path: "/v1/pairings/\(pairingID)", token: credentials.token)
        return try JSONDecoder().decode(WriterClaim.self, from: data)
    }
    /// User must compare the recipient shown by inspect before invoking this method.
    public func approve(pairingID: String, claim: WriterClaim) async throws {
        guard claim.state == "claimed", let id = claim.claimId, let recipient = claim.recipientPublicKey else { throw SyncError.configuration }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.signingPrivateKey)
        let wrap = try SnapshotKeyWrap.seal(key: SymmetricKey(data: credentials.snapshotKey), recipient: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(recipient)),
            context: [credentials.workspaceID,credentials.deviceID,credentials.epoch,credentials.keyID,id].joined(separator: "|"), signer: signer)
        _ = try await transport.request(path: "/v1/pairings/\(pairingID)/approve", method: "POST", token: credentials.token,
            body: JSONSerialization.data(withJSONObject: ["claimId": id, "wrappedSnapshotKey": wrap, "keyId": credentials.keyID, "sourcePublicKey": Base64URL.encode(signer.publicKey.rawRepresentation)]))
    }
}
