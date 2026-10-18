import Foundation
import CryptoKit
import QuotaCore

public enum TransportError: Error { case endpoint, rejected(Int), oversized, malformed, unavailable }
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Tokens are sent only to the explicitly configured HTTPS origin, never to redirects.
public struct SyncTransport: Sendable {
    public let baseURL: URL
    private var responder: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?
    public init(baseURL: URL) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, ["", "/"].contains(baseURL.path) else { throw TransportError.endpoint }
        self.baseURL = baseURL
    }
    init(baseURL: URL, responder: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) throws {
        try self.init(baseURL: baseURL); self.responder = responder
    }
    public func request(path: String, method: String = "GET", token: String, body: Data? = nil, etag: String? = nil, bootstrap: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let activityV2 = path == "/v2/activity-display" || path.range(of: "^/v2/activities/[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
        guard path.hasPrefix("/v1/") || activityV2, !path.contains(".."), !path.contains("?"), !path.contains("#"), token.count <= 2048 else { throw TransportError.endpoint }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method; request.timeoutInterval = 10; request.httpBody = body
        guard !bootstrap || path == "/v1/bootstrap" else { throw TransportError.endpoint }
        request.setValue(bootstrap ? token : "Bearer " + token, forHTTPHeaderField: bootstrap ? "X-Bootstrap-Token" : "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let responder { return try await responder(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed }
        // A sealed 128 KiB snapshot arrives as ~176 KB of envelope JSON.
        guard http.expectedContentLength <= 262_144 else { throw TransportError.oversized }
        var data = Data()
        for try await byte in bytes { guard data.count < 262_144 else { throw TransportError.oversized }; data.append(byte) }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else { throw TransportError.rejected(http.statusCode) }
        return (data, http)
    }
}

/// One foreground or system-granted pull; no background loop and no Provider access.
public actor SnapshotClient {
    private let transport: SyncTransport
    private let cache: VerifiedCache
    private let token: String
    private let key: SymmetricKey
    private var etag: String?
    private var lastAttempt: Date?
    private var active: Task<Snapshot?, Error>?
    public private(set) var clockOffset: TimeInterval = 0
    public init(transport: SyncTransport, cache: VerifiedCache, token: String, key: SymmetricKey) {
        self.transport = transport; self.cache = cache; self.token = token; self.key = key
    }
    public func cached() async throws -> Snapshot? { try await cache.latest(key: key) }
    public func refresh(now: Date = Date()) async throws -> Snapshot? {
        if let active { return try await active.value }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 10 { return try await cached() }
        lastAttempt = now
        let task = Task { try await self.pull() }
        active = task
        defer { active = nil }
        return try await task.value
    }
    private func pull() async throws -> Snapshot? {
        let start = Date()
        let (data, response) = try await transport.request(path: "/v1/snapshot", token: token, etag: etag)
        if let value = response.value(forHTTPHeaderField: "Date") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let server = formatter.date(from: value) { clockOffset = server.timeIntervalSince(start.addingTimeInterval(Date().timeIntervalSince(start) / 2)) }
        }
        if response.statusCode == 304 { return try await cached() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["envelope", "receipt"], let envelope = object["envelope"] as? [String: Any] else { throw TransportError.malformed }
        let snapshot = try await cache.accept(JSONSerialization.data(withJSONObject: envelope), key: key)
        etag = response.value(forHTTPHeaderField: "ETag")
        return snapshot
    }
}
