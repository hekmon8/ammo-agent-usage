import Foundation
import QuotaCore

public enum APNSEnvironment: String, Codable, Sendable { case sandbox, production }

/// Configuration presence is not a delivery receipt. The app still needs a signed
/// push entitlement, a token, explicit consent, and a successful registration.
public struct LiveUpdateCapabilities: Decodable, Sendable {
    public let pushMode: String
    public let activityContentVersions: [Int]?
    public var canRegister: Bool { pushMode == "own_team" }
    public var canRegisterGroups: Bool { canRegister && activityContentVersions?.contains(2) == true }
}

public struct LiveActivityClient: Sendable {
    private let transport: SyncTransport
    private let token: String

    public init(credentials: ViewerCredentials) throws {
        transport = try SyncTransport(baseURL: credentials.endpoint)
        token = credentials.token
    }

    init(transport: SyncTransport, token: String) {
        self.transport = transport; self.token = token
    }

    public func capabilities() async throws -> LiveUpdateCapabilities {
        let (data, _) = try await transport.request(path: "/v1/capabilities", token: token)
        return try JSONDecoder().decode(LiveUpdateCapabilities.self, from: data)
    }

    public func register(activityID: String, windowID: String, pushToken: Data,
                         environment: APNSEnvironment, endsAt: Date, consent: Bool,
                         now: Date = .now) async throws {
        // The service bounds each registration to a rolling 4-hour window. A longer
        // session registers its first coverage slice and re-registers to extend;
        // rejecting outright would leave every 8-hour session without remote push.
        let boundedEndsAt = min(endsAt, now.addingTimeInterval(4 * 60 * 60))
        guard consent, validLiveID(activityID), validLiveID(windowID),
              !pushToken.isEmpty, pushToken.count <= 512,
              endsAt > now, boundedEndsAt > now else { throw SyncError.configuration }
        let body = try JSONSerialization.data(withJSONObject: [
            "windowId": windowID,
            "activityToken": pushToken.map { String(format: "%02x", $0) }.joined(),
            "environment": environment.rawValue,
            "endsAt": liveTimestamp(boundedEndsAt),
            "projectionConsent": true
        ])
        let (data, _) = try await transport.request(path: "/v1/activities/" + activityID, method: "PUT", token: token, body: body)
        try requireLiveAcknowledgement(data)
    }

    public func end(activityID: String) async throws {
        guard validLiveID(activityID) else { throw SyncError.configuration }
        do {
            let (data, _) = try await transport.request(path: "/v1/activities/" + activityID, method: "DELETE", token: token)
            try requireLiveAcknowledgement(data)
        } catch TransportError.rejected(404) { /* Idempotent after expiration/removal. */ }
    }

    /// Registers the device's system push token so the Mac can relay
    /// balance/budget alerts as standard notifications. The token is stored
    /// encrypted server-side and scoped to this viewer device.
    public func registerAlertToken(_ pushToken: Data, environment: APNSEnvironment) async throws {
        guard !pushToken.isEmpty, pushToken.count <= 512 else { throw SyncError.configuration }
        let body = try JSONSerialization.data(withJSONObject: [
            "token": pushToken.map { String(format: "%02x", $0) }.joined(),
            "environment": environment.rawValue
        ])
        let (data, _) = try await transport.request(path: "/v1/alert-token", method: "PUT", token: token, body: body)
        try requireLiveAcknowledgement(data)
    }

    public func removeAlertToken() async throws {
        do {
            let (data, _) = try await transport.request(path: "/v1/alert-token", method: "DELETE", token: token)
            try requireLiveAcknowledgement(data)
        } catch TransportError.rejected(404) { /* Idempotent across service upgrades. */ }
    }
}

/// Relay outcome reported by the service; acceptance is not device delivery.
public struct BillingAlertRelayResult: Sendable {
    public let accepted: Int
    public let failed: Int
}

public enum BillingAlertSeverity: String, Sendable { case info, warning, critical }

/// Writer-side control surface: the Mac owns the alert rules and the relay
/// switch; the iPhone always keeps its own authorization switch.
public struct BillingAlertRelay: Sendable {
    private let transport: SyncTransport
    private let token: String

    public init(credentials: WriterCredentials) throws {
        transport = try SyncTransport(baseURL: credentials.endpoint)
        token = credentials.token
    }

    init(transport: SyncTransport, token: String) {
        self.transport = transport; self.token = token
    }

    public func setPhoneAlertsEnabled(_ enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["phoneAlertsEnabled": enabled])
        let (data, _) = try await transport.request(path: "/v1/alert-settings", method: "PUT", token: token, body: body)
        try requireLiveAcknowledgement(data)
    }

    public func publish(alertID: String, title: String, body: String,
                        severity: BillingAlertSeverity) async throws -> BillingAlertRelayResult {
        guard validLiveID(alertID), title.count <= 120, body.count <= 400 else { throw SyncError.configuration }
        let payload = try JSONSerialization.data(withJSONObject: [
            "alertId": alertID, "title": String(title.prefix(120)),
            "body": String(body.prefix(400)), "severity": severity.rawValue
        ])
        let (data, _) = try await transport.request(path: "/v1/alert-push", method: "POST", token: token, body: payload)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["ok"] as? Bool == true else { throw TransportError.malformed }
        return BillingAlertRelayResult(accepted: result["accepted"] as? Int ?? 0, failed: result["failed"] as? Int ?? 0)
    }
}

/// The only plaintext quota projection permitted by the remote-monitoring opt-in.
/// Account identity, amounts, history, and Provider credentials cannot be encoded.
public struct LiveQuotaProjection: Codable, Sendable {
    public let sequence: Int64
    public let windowId, label: String
    public let remainingBps: Int?
    public let displayState: String
    public let observedAt, staleAt, resetsAt: String?

    public init?(window: QuotaWindow, sequence: Int64, now: Date = .now) {
        guard sequence > 0, validLiveID(window.id), window.unit == .percent, window.quality == .reported else { return nil }
        let value = QuotaPresentation(window: window, now: now)
        // A future observation must not become fresh through normalization.
        guard value.state != .clockSkew else { return nil }
        self.sequence = sequence
        windowId = window.id
        label = String((window.providerId + " · " + window.quotaKey).prefix(32))
        remainingBps = value.visibleBps
        displayState = window.fetchOutcome != .ok && ![.authRequired, .unavailable].contains(value.state)
            ? "stale" : value.state.rawValue
        observedAt = window.observedAt.flatMap(QuotaRules.date).map(liveTimestamp)
        staleAt = window.staleAt.flatMap(QuotaRules.date).map(liveTimestamp)
        resetsAt = window.window.resetsAt.flatMap(QuotaRules.date).map(liveTimestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sequence, forKey: .sequence); try c.encode(windowId, forKey: .windowId)
        try c.encode(label, forKey: .label); try c.encode(remainingBps, forKey: .remainingBps)
        try c.encode(displayState, forKey: .displayState); try c.encode(observedAt, forKey: .observedAt)
        try c.encode(staleAt, forKey: .staleAt); try c.encode(resetsAt, forKey: .resetsAt)
    }
}

public struct LiveProjectionResult: Sendable {
    /// Accepted by the sync service, not independently confirmed on an iPhone.
    public let accepted: Int
    public let failed: Int
}

/// Serializes publications across windows and keeps consent independent from
/// encrypted snapshot upload. A failed projection never invalidates local data.
public actor LiveProjectionClient {
    private let transport: SyncTransport
    private let token: String
    private var enabled = false
    private var sequences: [String: Int64] = [:]
    private var active: (id: UUID, task: Task<LiveProjectionResult, Never>)?

    public init(credentials: WriterCredentials) throws {
        transport = try SyncTransport(baseURL: credentials.endpoint); token = credentials.token
    }

    init(transport: SyncTransport, token: String) {
        self.transport = transport; self.token = token
    }

    public func setConsent(_ allowed: Bool) {
        enabled = allowed
        if !allowed { active?.task.cancel() }
    }

    public func upload(_ snapshot: Snapshot, now: Date = .now) async -> LiveProjectionResult {
        guard enabled else { return LiveProjectionResult(accepted: 0, failed: 0) }
        if let previous = active {
            _ = await previous.task.value
            if active?.id == previous.id { active = nil }
            return await upload(snapshot, now: now)
        }
        return await begin(snapshot, now: now)
    }

    private func begin(_ snapshot: Snapshot, now: Date) async -> LiveProjectionResult {
        guard enabled, !Task.isCancelled else { return LiveProjectionResult(accepted: 0, failed: 0) }
        let id = UUID()
        let task = Task { await self.perform(snapshot, now: now) }
        active = (id, task)
        let result = await task.value
        if active?.id == id { active = nil }
        return result
    }

    private func perform(_ snapshot: Snapshot, now: Date) async -> LiveProjectionResult {
        var accepted = 0, failed = 0
        for window in snapshot.windows {
            guard enabled, !Task.isCancelled else { break }
            guard snapshot.sourceSequence > (sequences[window.id] ?? 0),
                  let projection = LiveQuotaProjection(window: window, sequence: snapshot.sourceSequence, now: now) else { continue }
            do {
                let body = try JSONEncoder().encode(projection)
                guard body.count <= 1024 else { throw SyncError.configuration }
                let (data, _) = try await transport.request(path: "/v1/live-projections", method: "PUT", token: token, body: body)
                try requireLiveAcknowledgement(data)
                sequences[window.id] = snapshot.sourceSequence; accepted += 1
            } catch { failed += 1 }
        }
        return LiveProjectionResult(accepted: accepted, failed: failed)
    }
}

private func validLiveID(_ id: String) -> Bool {
    id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
}

private func liveTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func requireLiveAcknowledgement(_ data: Data) throws {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          result["ok"] as? Bool == true else { throw TransportError.malformed }
}
