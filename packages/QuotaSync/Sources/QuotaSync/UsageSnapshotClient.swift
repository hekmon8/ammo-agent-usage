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
    private struct Refresh {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UsageSnapshotRefresh, Error>]
    }
    private var active: Refresh?
    // Internal observation lets concurrency tests wait for actual registration.
    var refreshWaiterCount: Int { active?.waiters.count ?? 0 }
    private var lastOutcome: Result<UsageSnapshotRefresh, Error>?
    public init(transport: SyncTransport, cache: VerifiedUsageCache, token: String, key: SymmetricKey) {
        self.transport = transport; self.cache = cache; self.token = token; self.key = key
    }
    public func cached() async throws -> TokenUsageSnapshot? { try await cache.latest(key: key) }
    public func refresh(now: Date = Date()) async throws -> UsageSnapshotRefresh {
        try Task.checkCancellation()
        if active == nil, let lastAttempt, now.timeIntervalSince(lastAttempt) < 10, let lastOutcome { return try lastOutcome.get() }
        let waiter = UUID()
        let value: UsageSnapshotRefresh = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if active != nil {
                    active?.waiters[waiter] = continuation
                    return
                }
                lastAttempt = now
                let id = UUID()
                let task = Task {
                    let result: Result<UsageSnapshotRefresh, Error>
                    do { result = .success(try await self.pull()) }
                    catch { result = .failure(error) }
                    self.finishRefresh(id, result: result)
                }
                active = Refresh(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancelRefresh(waiter) }
        }
        try Task.checkCancellation()
        return value
    }

    private func cancelRefresh(_ waiter: UUID) {
        guard let continuation = active?.waiters.removeValue(forKey: waiter) else { return }
        if active?.waiters.isEmpty == true {
            active?.task.cancel()
            active = nil
            // A cancelled attempt must not throttle a new foreground request.
            lastAttempt = nil
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finishRefresh(_ id: UUID, result: Result<UsageSnapshotRefresh, Error>) {
        // An abandoned request may return after its replacement has started.
        guard let refresh = active, refresh.id == id else { return }
        active = nil
        lastOutcome = result
        for continuation in refresh.waiters.values { continuation.resume(with: result) }
    }
    private func pull() async throws -> UsageSnapshotRefresh {
        try Task.checkCancellation()
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.request(path: "/v1/usage", token: token, etag: etag) }
        catch TransportError.rejected(let status) where status == 404 || status == 405 {
            try Task.checkCancellation()
            return UsageSnapshotRefresh(snapshot: try await cached(), verified: false)
        }
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let snapshot = try await cache.accept(JSONSerialization.data(withJSONObject: envelope), key: key)
        try Task.checkCancellation()
        etag = response.value(forHTTPHeaderField: "ETag")
        return UsageSnapshotRefresh(snapshot: snapshot, verified: true)
    }
}
