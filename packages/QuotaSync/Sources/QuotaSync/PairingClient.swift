import Foundation
import CryptoKit

public struct PairingInvitation: Codable, Sendable {
    public let version: Int
    public let endpoint: URL
    public let pairingId, secret, sourcePublicKey: String
    public init(endpoint: URL, pairingId: String, secret: String, sourcePublicKey: String) {
        version = 1; self.endpoint = endpoint; self.pairingId = pairingId; self.secret = secret; self.sourcePublicKey = sourcePublicKey
    }
    public var fingerprint: String { (try? Base64URL.decode(sourcePublicKey)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "" }
    public func encodedURL() throws -> URL {
        guard let url = URL(string: "quotaisland://pair#" + Base64URL.encode(try JSONEncoder().encode(self))) else { throw SyncError.configuration }
        return url
    }
    public static func parse(_ url: URL) throws -> Self {
        guard url.scheme == "quotaisland", url.host == "pair", url.query == nil, let fragment = url.fragment, fragment.count <= 4096 else { throw SyncError.configuration }
        let data = try Base64URL.decode(fragment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version","endpoint","pairingId","secret","sourcePublicKey"] else { throw SyncError.configuration }
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try SyncTransport(baseURL: value.endpoint)
        guard value.version == 1, value.pairingId.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              try Base64URL.decode(value.secret).count == 32, try Base64URL.decode(value.sourcePublicKey).count == 32 else { throw SyncError.configuration }
        return value
    }
}
public struct ViewerCredentials: Codable, Sendable {
    public let endpoint: URL
    public let deviceID, token: String
    public let trust: SourceTrust
    public let snapshotKey, recipientPrivateKey: Data
}
public struct PairingClaim: Codable, Sendable {
    public let invitation: PairingInvitation
    public let claimID, claimToken: String
    public let recipientPrivateKey: Data
}
public enum PairingClient {
    /// Caller displays invitation host/fingerprint and obtains a foreground confirmation first.
    public static func claim(_ invitation: PairingInvitation, deviceName: String) async throws -> PairingClaim {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let transport = try SyncTransport(baseURL: invitation.endpoint)
        let body = try JSONSerialization.data(withJSONObject: ["deviceName": String(deviceName.prefix(48)), "recipientPublicKey": Base64URL.encode(recipient.publicKey.rawRepresentation)])
        let (data, _) = try await transport.request(path: "/v1/pairings/\(invitation.pairingId)/claim", method: "POST", token: invitation.secret, body: body)
        struct Result: Decodable { let claimId, claimToken, state: String }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.state == "claimed" else { throw SyncError.configuration }
        return PairingClaim(invitation: invitation, claimID: result.claimId, claimToken: result.claimToken, recipientPrivateKey: recipient.rawRepresentation)
    }
    public static func result(_ claim: PairingClaim) async throws -> ViewerCredentials? {
        let transport = try SyncTransport(baseURL: claim.invitation.endpoint)
        let (data, _) = try await transport.request(path: "/v1/pairings/\(claim.invitation.pairingId)/result", token: claim.claimToken)
        struct Result: Decodable { let state: String; let deviceId, deviceToken, wrappedSnapshotKey, sourcePublicKey, workspaceId, sourceDeviceId, sourceEpoch, keyId: String? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        if result.state == "claimed" { return nil }
        guard result.state == "approved", let device = result.deviceId, let token = result.deviceToken, let wrap = result.wrappedSnapshotKey,
              let sourceKey = result.sourcePublicKey, sourceKey == claim.invitation.sourcePublicKey,
              let workspace = result.workspaceId, let source = result.sourceDeviceId, let epoch = result.sourceEpoch, let keyID = result.keyId else { throw SyncError.untrustedSource }
        let publicKey = try Base64URL.decode(sourceKey)
        let key = try SnapshotKeyWrap.open(wrap, recipient: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: claim.recipientPrivateKey), context: [workspace,source,epoch,keyID,claim.claimID].joined(separator: "|"), sourceKey: Curve25519.Signing.PublicKey(rawRepresentation: publicKey))
        return ViewerCredentials(endpoint: claim.invitation.endpoint, deviceID: device, token: token,
            trust: SourceTrust(workspaceID: workspace, deviceID: source, epoch: epoch, keyID: keyID, publicKey: publicKey), snapshotKey: key.withUnsafeBytes { Data($0) }, recipientPrivateKey: claim.recipientPrivateKey)
    }
    /// Call only after the full ViewerCredentials were durably saved in Keychain.
    public static func acknowledge(_ claim: PairingClaim, transport supplied: SyncTransport? = nil) async throws {
        let transport = try supplied ?? SyncTransport(baseURL: claim.invitation.endpoint)
        let (data, _) = try await transport.request(path: "/v1/pairings/\(claim.invitation.pairingId)/ack", method: "POST", token: claim.claimToken, body: JSONSerialization.data(withJSONObject: ["claimId": claim.claimID]))
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(response.keys) == ["ok"],
              let ok = response["ok"] as? Bool, ok else { throw TransportError.malformed }
    }
}
