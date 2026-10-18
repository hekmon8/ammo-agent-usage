import Foundation
import CryptoKit

public struct PairedDevice: Codable, Sendable {
    public let deviceId, name, role: String
    public let revoked: Bool
    public let recipientPublicKey: String?
}
public struct RotationDraft: Codable, Sendable {
    public let previous: WriterCredentials
    public let next: WriterCredentials
    public let revokedDeviceIDs: [String]
    public let request: Data
}
public enum SourceRotation {
    static func trustMessage(workspace: String, source: String, oldEpoch: String, newEpoch: String, publicKey: String, keyID: String) -> Data {
        Data(["QI-ROTATION-TRUST", "1", workspace, source, oldEpoch, newEpoch, publicKey, keyID].joined(separator: "|").utf8)
    }
    public static func devices(_ credentials: WriterCredentials) async throws -> [PairedDevice] {
        let (data, _) = try await SyncTransport(baseURL: credentials.endpoint).request(path: "/v1/devices", token: credentials.token)
        return try JSONDecoder().decode([PairedDevice].self, from: data)
    }
    public static func revoke(_ credentials: WriterCredentials, deviceID: String, transport supplied: SyncTransport? = nil) async throws {
        guard deviceID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil, deviceID != credentials.deviceID else { throw SyncError.configuration }
        let transport = try supplied ?? SyncTransport(baseURL: credentials.endpoint)
        guard transport.baseURL == credentials.endpoint else { throw SyncError.configuration }
        let (data, _) = try await transport.request(path: "/v1/devices/" + deviceID, method: "DELETE", token: credentials.token)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(result.keys) == ["ok"], result["ok"] as? Bool == true else { throw TransportError.malformed }
    }
    public static func prepare(_ credentials: WriterCredentials, devices: [PairedDevice], revoking revokedDeviceIDs: [String]) throws -> RotationDraft {
        let activeViewers = devices.filter { $0.role == "viewer" && !$0.revoked }
        let activeIDs = Set(activeViewers.map(\.deviceId)), revokedIDs = Set(revokedDeviceIDs)
        guard !revokedDeviceIDs.isEmpty, revokedDeviceIDs.count <= 32, revokedIDs.count == revokedDeviceIDs.count,
              activeIDs.count == activeViewers.count, revokedIDs.isSubset(of: activeIDs),
              revokedDeviceIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil && $0 != credentials.deviceID })
        else { throw SyncError.configuration }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.signingPrivateKey)
        let nextSigner = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let next = WriterCredentials(endpoint: credentials.endpoint, workspaceID: credentials.workspaceID, deviceID: credentials.deviceID,
            epoch: UUID().uuidString, token: credentials.token, keyID: "key-" + UUID().uuidString,
            signingPrivateKey: nextSigner.rawRepresentation, snapshotKey: key.withUnsafeBytes { Data($0) })
        let publicKey = Base64URL.encode(nextSigner.publicKey.rawRepresentation)
        var wraps: [[String: String]] = []
        for device in activeViewers.filter({ !revokedIDs.contains($0.deviceId) }).sorted(by: { $0.deviceId < $1.deviceId }) {
            guard let recipient = device.recipientPublicKey else { throw SyncError.configuration }
            let wrap = try SnapshotKeyWrap.seal(key: key, recipient: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(recipient)),
                context: [next.workspaceID,next.deviceID,next.epoch,next.keyID,device.deviceId].joined(separator: "|"), signer: signer)
            wraps.append(["deviceId": device.deviceId, "wrappedSnapshotKey": wrap])
        }
        guard wraps.count <= 32 else { throw SyncError.configuration }
        let header = ["QI-ROTATE","1",next.workspaceID,next.deviceID,credentials.epoch,next.epoch,publicKey,next.keyID].joined(separator: "|")
        let message = Data((header + "\n" + wraps.map { $0["deviceId"]! + "|" + $0["wrappedSnapshotKey"]! + "\n" }.joined()).utf8)
        let trust = trustMessage(workspace: next.workspaceID, source: next.deviceID, oldEpoch: credentials.epoch, newEpoch: next.epoch, publicKey: publicKey, keyID: next.keyID)
        let request = try JSONSerialization.data(withJSONObject: ["userConfirmation":"rotate_source_key", "oldSourceEpoch":credentials.epoch,
            "newSourceEpoch":next.epoch,"newSourcePublicKey":publicKey,"keyId":next.keyID,"wraps":wraps,
            "signature":Base64URL.encode(signer.signature(for: message)),"trustSignature":Base64URL.encode(signer.signature(for: trust))])
        return RotationDraft(previous: credentials, next: next, revokedDeviceIDs: revokedDeviceIDs.sorted(), request: request)
    }
    public static func submit(_ draft: RotationDraft, vault: any SecretStoring, transport supplied: SyncTransport? = nil) async throws -> WriterCredentials {
        let revokedIDs = Set(draft.revokedDeviceIDs)
        guard !draft.revokedDeviceIDs.isEmpty, draft.revokedDeviceIDs.count <= 32,
              revokedIDs.count == draft.revokedDeviceIDs.count,
              draft.revokedDeviceIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil && $0 != draft.previous.deviceID })
        else { throw SyncError.configuration }
        try vault.save(JSONEncoder().encode(draft), account: "rotation-draft")
        let transport = try supplied ?? SyncTransport(baseURL: draft.previous.endpoint)
        guard transport.baseURL == draft.previous.endpoint else { throw SyncError.configuration }
        // DELETE is idempotent. Keeping the complete draft until the rotation receipt
        // makes an ambiguous response safe to resume without losing revocation intent.
        for deviceID in draft.revokedDeviceIDs.sorted() {
            try await revoke(draft.previous, deviceID: deviceID, transport: transport)
        }
        let (data, _) = try await transport.request(path: "/v1/source-key-rotations", method: "POST", token: draft.previous.token, body: draft.request)
        struct Receipt: Decodable { let workspaceId, sourceEpoch, keyId: String }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.workspaceId == draft.next.workspaceID, receipt.sourceEpoch == draft.next.epoch, receipt.keyId == draft.next.keyID else { throw SyncError.untrustedSource }
        try vault.save(JSONEncoder().encode(draft.next), account: "writer")
        try vault.remove("rotation-draft")
        return draft.next
    }
    /// Returns a cryptographically verified proposal. Caller must confirm the new source pin before saving it.
    public static func proposedViewerCredentials(_ current: ViewerCredentials) async throws -> ViewerCredentials {
        let (data, _) = try await SyncTransport(baseURL: current.endpoint).request(path: "/v1/device-key-wrap", token: current.token)
        return try verifyViewerProposal(data, current: current)
    }
    static func verifyViewerProposal(_ data: Data, current: ViewerCredentials) throws -> ViewerCredentials {
        struct Proof: Decodable { let oldSourceEpoch, sourceEpoch, keyId, wrappedSnapshotKey, newSourcePublicKey, trustSignature, sourceDeviceId: String }
        let proof = try JSONDecoder().decode(Proof.self, from: data)
        guard proof.oldSourceEpoch == current.trust.epoch, proof.sourceEpoch != current.trust.epoch, proof.sourceDeviceId == current.trust.deviceID else { throw SyncError.untrustedSource }
        let oldKey = try Curve25519.Signing.PublicKey(rawRepresentation: current.trust.publicKey)
        let message = trustMessage(workspace: current.trust.workspaceID, source: proof.sourceDeviceId, oldEpoch: proof.oldSourceEpoch,
            newEpoch: proof.sourceEpoch, publicKey: proof.newSourcePublicKey, keyID: proof.keyId)
        guard try oldKey.isValidSignature(Base64URL.decode(proof.trustSignature), for: message) else { throw SyncError.untrustedSource }
        let key = try SnapshotKeyWrap.open(proof.wrappedSnapshotKey, recipient: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: current.recipientPrivateKey),
            context: [current.trust.workspaceID,proof.sourceDeviceId,proof.sourceEpoch,proof.keyId,current.deviceID].joined(separator: "|"), sourceKey: oldKey)
        let publicKey = try Base64URL.decode(proof.newSourcePublicKey)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return ViewerCredentials(endpoint: current.endpoint, deviceID: current.deviceID, token: current.token,
            trust: SourceTrust(workspaceID: current.trust.workspaceID, deviceID: proof.sourceDeviceId, epoch: proof.sourceEpoch, keyID: proof.keyId, publicKey: publicKey),
            snapshotKey: key.withUnsafeBytes { Data($0) }, recipientPrivateKey: current.recipientPrivateKey)
    }
}
