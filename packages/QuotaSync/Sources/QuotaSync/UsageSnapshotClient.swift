import Foundation
import CryptoKit
import QuotaCore

/// One independent pull of the encrypted token aggregate. A paired phone uses
/// the same trusted source and keys as quota sync, with a separate cache/ETag.
public struct UsageSnapshotRefresh: Sendable {
    public let snapshot: TokenUsageSnapshot?
    /// True only after a verified 200 response or a valid conditional 304.
    public let verified: Bool
}

public actor UsageSnapshotClient {
    private let transport: SyncTransport
    private let cache: VerifiedUsageCache
    private let token: String
    private let key: SymmetricKey
    private var etag: String?
    private var lastAttempt: Date?
    private var active: Task<UsageSnapshotRefresh, Error>?
    private var lastOutcome: Result<UsageSnapshotRefresh, Error>?
    public init(transport: SyncTransport, cache: VerifiedUsageCache, token: String, key: SymmetricKey) {
        self.transport = transport; self.cache = cache; self.token = token; self.key = key
    }
    public func cached() async throws -> TokenUsageSnapshot? { try await cache.latest(key: key) }
    public func refresh(now: Date = Date()) async throws -> UsageSnapshotRefresh {
        if let active { return try await active.value }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 10, let lastOutcome { return try lastOutcome.get() }
        lastAttempt = now
        let task = Task { try await self.pull() }
        active = task
        defer { active = nil }
        do {
            let value = try await task.value
            lastOutcome = .success(value)
            return value
        } catch {
            lastOutcome = .failure(error)
            throw error
        }
    }
    private func pull() async throws -> UsageSnapshotRefresh {
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.request(path: "/v1/usage", token: token, etag: etag) }
        catch TransportError.rejected(let status) where status == 404 || status == 405 {
            return UsageSnapshotRefresh(snapshot: try await cached(), verified: false)
        }
        let (data, response) = result
        // An old Worker or a source that has not uploaded usage is harmless to
        // quota refresh. Keep a last-good observation, including its timestamp.
        if response.statusCode == 404 || response.statusCode == 405 {
            return UsageSnapshotRefresh(snapshot: try await cached(), verified: false)
        }
        if response.statusCode == 304 {
            guard etag != nil else { throw TransportError.malformed }
            return UsageSnapshotRefresh(snapshot: try await cached(), verified: true)
        }
        guard response.statusCode == 200 else { throw TransportError.rejected(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["envelope", "receipt"], let envelope = object["envelope"] as? [String: Any] else { throw TransportError.malformed }
        let snapshot = try await cache.accept(JSONSerialization.data(withJSONObject: envelope), key: key)
        etag = response.value(forHTTPHeaderField: "ETag")
        return UsageSnapshotRefresh(snapshot: snapshot, verified: true)
    }
}
