import Foundation
import CryptoKit
import QuotaCore

/// A separate, explicitly consented projection. No account names, credentials,
/// history, source paths, or original window identifiers cross this boundary.
/// Windows of one account share an opaque `account` digest, so several accounts
/// of one provider can be grouped without learning which account they are.
public enum RemoteMCPProjection {
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func encode(_ snapshot: Snapshot, sourceEpoch: String) throws -> Data {
        let windows: [[String: Any]] = snapshot.windows.map { w in
            ["id": digest(w.id), "account": digest(w.providerId + "/" + w.accountId),
             "providerId": w.providerId, "unit": w.unit.rawValue, "currency": w.currency as Any? ?? NSNull(), "quotaKey": w.quotaKey, "availability": w.availability.rawValue,
             "remainingBps": w.remainingBps as Any? ?? NSNull(), "amount": w.amount as Any? ?? NSNull(),
             "limit": w.limit as Any? ?? NSNull(), "quality": w.quality.rawValue,
             "fetchOutcome": w.fetchOutcome.rawValue, "observedAt": w.observedAt as Any? ?? NSNull(),
             "staleAt": w.staleAt as Any? ?? NSNull(), "resetsAt": w.window.resetsAt as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: ["sequence": snapshot.sourceSequence,
            "sourceEpoch": sourceEpoch, "capturedAt": snapshot.capturedAt, "windows": windows], options: [.sortedKeys])
    }
}

public actor RemoteMCPClient {
    private let credentials: WriterCredentials
    private let transport: SyncTransport
    private var enabled = false
    private var generation = UUID()
    private var active: (id: UUID, task: Task<Void, Error>)?
    public init(credentials: WriterCredentials, transport: SyncTransport? = nil) throws {
        self.credentials = credentials
        self.transport = try transport ?? SyncTransport(baseURL: credentials.endpoint)
    }
    public func resumeConsent() { enabled = true }
    public func pause() async {
        enabled = false; generation = UUID()
        _ = try? await active?.task.value
    }
    private func enqueue(path: String, method: String, body: Data? = nil) async throws {
        let previous = active?.task, id = UUID()
        let transport = self.transport, token = credentials.token
        let task = Task {
            _ = try? await previous?.value
            let (data, _) = try await transport.request(path: path, method: method, token: token, body: body)
            struct Acknowledgement: Decodable { let accepted: Bool }
            guard try JSONDecoder().decode(Acknowledgement.self, from: data).accepted else { throw SyncError.configuration }
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        try await task.value
    }
    /// Caller's Keychain owns the generated token before this network request.
    public func enable(token: String) async throws {
        guard token.count >= 32 else { throw SyncError.configuration }
        enabled = false
        let attempt = UUID(); generation = attempt
        try await enqueue(path: "/v1/mcp-access", method: "PUT",
            body: JSONSerialization.data(withJSONObject: ["tokenHash": tokenHash(token), "consent": "share_redacted_quotas", "sourceEpoch": credentials.epoch]))
        guard generation == attempt else { throw CancellationError() }
        enabled = true
    }
    private func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func keepKeyUntilRevoked(token: String) async throws {
        try await enqueue(path: "/v1/mcp-access", method: "PATCH",
                          body: JSONEncoder().encode(["lifetime": "until_revoked", "tokenHash": tokenHash(token)]))
    }
    public func setReceivedShares(_ grants: [ShareGrant], token: String) async throws {
        struct Reference: Encodable { let shareId, viewerTokenHash: String }
        struct Update: Encodable { let tokenHash: String; let shares: [Reference] }
        let shares = grants.compactMap { grant -> Reference? in
            let endpoint = credentials.endpoint
            guard grant.endpoint.scheme == endpoint.scheme,
                  grant.endpoint.host?.lowercased() == endpoint.host?.lowercased(),
                  (grant.endpoint.port ?? 443) == (endpoint.port ?? 443) else { return nil }
            return Reference(shareId: grant.shareId, viewerTokenHash: tokenHash(grant.token))
        }
        try await enqueue(path: "/v1/mcp-shares", method: "PUT",
                          body: JSONEncoder().encode(Update(tokenHash: tokenHash(token), shares: shares)))
    }
    public func disable() async throws {
        enabled = false; generation = UUID()
        try await enqueue(path: "/v1/mcp-access", method: "DELETE")
    }
    public func upload(_ snapshot: Snapshot) async throws {
        guard enabled else { return }
        try await enqueue(path: "/v1/mcp-snapshot", method: "PUT",
                          body: RemoteMCPProjection.encode(snapshot, sourceEpoch: credentials.epoch))
    }
}
