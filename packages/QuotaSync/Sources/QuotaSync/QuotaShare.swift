import Foundation
import CryptoKit
import QuotaCore

/// A short-lived bearer invitation. Keep its URL out of logs and untrusted previews.
public struct ShareInvitation: Codable, Sendable {
    public let version: Int
    public let endpoint: URL
    public let shareId, secret: String

    public init(endpoint: URL, shareId: String, secret: String) {
        version = 1
        self.endpoint = endpoint
        self.shareId = shareId
        self.secret = secret
    }

    public func encodedURL() throws -> URL {
        try validate()
        guard let url = URL(string: "quotaisland://share#" + Base64URL.encode(try JSONEncoder().encode(self))) else {
            throw SyncError.configuration
        }
        return url
    }

    public static func parse(_ url: URL) throws -> Self {
        guard url.scheme == "quotaisland", url.host == "share", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil,
              let fragment = url.fragment, fragment.count <= 4096 else { throw SyncError.configuration }
        let data = try Base64URL.decode(fragment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "endpoint", "shareId", "secret"] else { throw SyncError.configuration }
        let invitation = try JSONDecoder().decode(Self.self, from: data)
        try invitation.validate()
        return invitation
    }

    private func validate() throws {
        guard version == 1, SharePath.valid(shareId),
              try Base64URL.decode(secret).count == 32 else { throw SyncError.configuration }
        _ = try SyncTransport(baseURL: endpoint)
    }
}

private enum SharePath {
    static func valid(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
    static func share(_ id: String) throws -> String {
        guard valid(id) else { throw SyncError.configuration }
        return "/v1/shares/\(id)"
    }
}

/// Stored in Keychain while the writer decides whether to approve the claim.
/// Unlike an invitation, it contains no invitation secret or account identity.
public struct ShareClaim: Codable, Sendable {
    public let endpoint: URL
    public let shareId, claimId, claimToken, verificationCode: String

    public init(endpoint: URL, shareId: String, claimId: String, claimToken: String, verificationCode: String) {
        self.endpoint = endpoint
        self.shareId = shareId
        self.claimId = claimId
        self.claimToken = claimToken
        self.verificationCode = verificationCode
    }
}

/// A read-only, per-share bearer grant; persist it in Keychain, not preferences.
public struct ShareGrant: Codable, Sendable {
    public let endpoint: URL
    public let shareId, token: String

    public init(endpoint: URL, shareId: String, token: String) {
        self.endpoint = endpoint
        self.shareId = shareId
        self.token = token
    }
}

/// Writer-only metadata. Never pass this value to a recipient surface: accountId is private.
public struct ShareRecord: Codable, Sendable {
    public let shareId, connectionId, providerId, accountId, label, state: String
    public let recipientName, claimId, verificationCode: String?
    public let expiresAt: String
}

/// The explicit, minimal plaintext disclosure: no account ID, aliases, provider credentials,
/// history, source metadata, or full-snapshot encryption key.
public struct ShareWindow: Codable, Sendable {
    public let quotaKey, unit: String
    public let currency: String?
    public let availability: String
    public let remainingBps: Int?
    public let amount, limit: String?
    public let quality, fetchOutcome: String
    public let observedAt, staleAt, resetsAt: String?

    public init(quotaKey: String, unit: String, currency: String?, availability: String,
                remainingBps: Int?, amount: String?, limit: String?, quality: String,
                fetchOutcome: String, observedAt: String?, staleAt: String?, resetsAt: String?) {
        self.quotaKey = quotaKey
        self.unit = unit
        self.currency = currency
        self.availability = availability
        self.remainingBps = remainingBps
        self.amount = amount
        self.limit = limit
        self.quality = quality
        self.fetchOutcome = fetchOutcome
        self.observedAt = observedAt
        self.staleAt = staleAt
        self.resetsAt = resetsAt
    }

    /// Call only after selecting the exact providerId AND accountId on the writer.
    public init(_ window: QuotaWindow) {
        self.init(quotaKey: window.quotaKey, unit: window.unit.rawValue, currency: window.currency,
                  availability: window.availability.rawValue, remainingBps: window.remainingBps,
                  amount: window.amount, limit: window.limit, quality: window.quality.rawValue,
                  fetchOutcome: window.fetchOutcome.rawValue, observedAt: window.observedAt,
                  staleAt: window.staleAt, resetsAt: window.window.resetsAt)
    }

    // Required nullable fields on the projection wire must be explicit JSON nulls.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(quotaKey, forKey: .quotaKey)
        try values.encode(unit, forKey: .unit)
        try values.encode(currency, forKey: .currency)
        try values.encode(availability, forKey: .availability)
        try values.encode(remainingBps, forKey: .remainingBps)
        try values.encode(amount, forKey: .amount)
        try values.encode(limit, forKey: .limit)
        try values.encode(quality, forKey: .quality)
        try values.encode(fetchOutcome, forKey: .fetchOutcome)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(staleAt, forKey: .staleAt)
        try values.encode(resetsAt, forKey: .resetsAt)
    }
}

public struct ShareProjection: Codable, Sendable {
    public let shareId, providerId, label, capturedAt: String
    public let windows: [ShareWindow]

    public init(shareId: String, providerId: String, label: String, capturedAt: String, windows: [ShareWindow]) {
        self.shareId = shareId
        self.providerId = providerId
        self.label = label
        self.capturedAt = capturedAt
        self.windows = windows
    }

    /// Filter before stripping account identity. Never select by provider alone:
    /// multiple independent accounts can have the same provider and quota key.
    public static func selected(_ snapshot: Snapshot, for share: ShareRecord) -> Self? {
        var windows: [ShareWindow] = []
        windows.reserveCapacity(min(snapshot.windows.count, 80))
        for window in snapshot.windows where window.providerId == share.providerId && window.accountId == share.accountId {
            guard windows.count < 80 else { return nil }
            windows.append(ShareWindow(window))
        }
        return Self(shareId: share.shareId, providerId: share.providerId,
                    label: share.label, capturedAt: snapshot.capturedAt, windows: windows)
    }

    fileprivate func publishingBody() throws -> Data {
        guard windows.count <= 80 else { throw SyncError.configuration }
        let body = PublishRequest(capturedAt: capturedAt, windows: windows)
        return try JSONEncoder().encode(body)
    }
    private struct PublishRequest: Encodable {
        let capturedAt: String
        let windows: [ShareWindow]
    }
}

public actor ShareWriter {
    private let credentials: WriterCredentials
    private let transport: SyncTransport

    public init(credentials: WriterCredentials, transport supplied: SyncTransport? = nil) throws {
        self.credentials = credentials
        transport = try supplied ?? SyncTransport(baseURL: credentials.endpoint)
        guard transport.baseURL == credentials.endpoint else { throw SyncError.configuration }
    }

    public func create(connectionId: String, providerId: String, accountId: String, label: String) async throws -> ShareInvitation {
        let secret = Base64URL.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        // The Worker hashes the textual bearer token, exactly as pairing does.
        let hash = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        let request = CreateRequest(connectionId: connectionId, providerId: providerId,
                                    accountId: accountId, label: label, inviteSecretHash: hash)
        let (data, _) = try await transport.request(path: "/v1/shares", method: "POST", token: credentials.token,
                                                    body: JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(CreateResponse.self, from: data)
        guard SharePath.valid(response.shareId), !response.expiresAt.isEmpty else { throw TransportError.malformed }
        return ShareInvitation(endpoint: credentials.endpoint, shareId: response.shareId, secret: secret)
    }

    public func list() async throws -> [ShareRecord] {
        let (data, _) = try await transport.request(path: "/v1/shares", token: credentials.token)
        return try JSONDecoder().decode([ShareRecord].self, from: data)
    }

    /// The UI must display the recipient and verification code before invoking approval.
    public func approve(shareId: String, claimId: String) async throws {
        guard SharePath.valid(claimId) else { throw SyncError.configuration }
        let path = try SharePath.share(shareId)
        let (data, _) = try await transport.request(path: path + "/approve", method: "POST", token: credentials.token,
                                                    body: JSONEncoder().encode(ApproveRequest(claimId: claimId)))
        let result = try JSONDecoder().decode(StateResponse.self, from: data)
        guard result.state == "approved" else { throw TransportError.malformed }
    }

    public func publish(shareId: String, projection: ShareProjection) async throws {
        guard shareId == projection.shareId else { throw SyncError.configuration }
        let path = try SharePath.share(shareId)
        let (data, _) = try await transport.request(path: path + "/projection", method: "PUT", token: credentials.token,
                                                    body: projection.publishingBody())
        let result = try JSONDecoder().decode(PublishResponse.self, from: data)
        guard result.accepted else { throw TransportError.malformed }
    }

    public func revoke(shareId: String) async throws {
        let path = try SharePath.share(shareId)
        let (data, _) = try await transport.request(path: path, method: "DELETE", token: credentials.token)
        let result = try JSONDecoder().decode(StateResponse.self, from: data)
        guard result.state == "revoked" else { throw TransportError.malformed }
    }

    private struct CreateRequest: Encodable {
        let connectionId, providerId, accountId, label, inviteSecretHash: String
    }
    private struct CreateResponse: Decodable { let shareId, expiresAt: String }
    private struct ApproveRequest: Encodable { let claimId: String }
    private struct StateResponse: Decodable { let state: String }
    private struct PublishResponse: Decodable { let accepted: Bool }
}

public enum ShareRecipient {
    public static func claim(invitation: ShareInvitation, recipientName: String) async throws -> ShareClaim {
        // Validate links even if the caller constructed an invitation without parsing a URL.
        _ = try ShareInvitation.parse(invitation.encodedURL())
        let transport = try SyncTransport(baseURL: invitation.endpoint)
        let path = try SharePath.share(invitation.shareId)
        let (data, _) = try await transport.request(path: path + "/claim", method: "POST", token: invitation.secret,
                                                    body: JSONEncoder().encode(ClaimRequest(recipientName: recipientName)))
        let result = try JSONDecoder().decode(ClaimResponse.self, from: data)
        guard SharePath.valid(result.claimId), !result.claimToken.isEmpty, !result.verificationCode.isEmpty else {
            throw TransportError.malformed
        }
        return ShareClaim(endpoint: invitation.endpoint, shareId: invitation.shareId, claimId: result.claimId,
                          claimToken: result.claimToken, verificationCode: result.verificationCode)
    }

    public static func result(claim: ShareClaim) async throws -> ShareGrant? {
        let transport = try SyncTransport(baseURL: claim.endpoint)
        let path = try SharePath.share(claim.shareId)
        let (data, _) = try await transport.request(path: path + "/result", token: claim.claimToken)
        let response = try JSONDecoder().decode(ResultResponse.self, from: data)
        switch response.state {
        case "claimed", "pending": return nil
        case "approved":
            guard let token = response.viewerToken, !token.isEmpty else { throw TransportError.malformed }
            return ShareGrant(endpoint: claim.endpoint, shareId: claim.shareId, token: token)
        case "expired", "revoked": throw SyncError.unavailable
        default: throw TransportError.malformed
        }
    }

    public static func projection(grant: ShareGrant) async throws -> ShareProjection {
        let transport = try SyncTransport(baseURL: grant.endpoint)
        let path = try SharePath.share(grant.shareId)
        let (data, _) = try await transport.request(path: path + "/projection", token: grant.token)
        let response = try JSONDecoder().decode(ShareProjection.self, from: data)
        guard response.shareId == grant.shareId, response.windows.count <= 80 else { throw TransportError.malformed }
        return response
    }

    private struct ClaimRequest: Encodable { let recipientName: String }
    private struct ClaimResponse: Decodable { let claimId, claimToken, verificationCode: String }
    private struct ResultResponse: Decodable { let state: String; let viewerToken: String? }
}
