import Foundation
import CryptoKit
import QuotaCore

/// A separate, explicitly consented projection. No account names, credentials,
/// history, source paths, or original window identifiers cross this boundary.
public enum RemoteMCPProjection {
    public static func encode(_ snapshot: Snapshot, sourceEpoch: String) throws -> Data {
        let windows: [[String: Any]] = snapshot.windows.map { w in
            ["id": SHA256.hash(data: Data(w.id.utf8)).map { String(format: "%02x", $0) }.joined(),
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
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        try await enqueue(path: "/v1/mcp-access", method: "PUT",
            body: JSONSerialization.data(withJSONObject: ["tokenHash": hash, "consent": "share_redacted_quotas", "sourceEpoch": credentials.epoch]))
        guard generation == attempt else { throw CancellationError() }
        enabled = true
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
