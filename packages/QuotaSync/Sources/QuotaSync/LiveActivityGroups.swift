import Foundation
import QuotaCore

public struct ActivityDisplayState: Decodable, Sendable, Equatable {
    public let displayRevision: Int64
    public let groupId: String?
    public let stopped: Bool
}

public struct ActivityGroupReceipt: Decodable, Sendable {
    public let ok: Bool
    public let displayRevision: Int64
    public let registrationRevision: Int64?
    public let groupId: String?
    public let stopped: Bool
}

/// A separate v2 route prevents old single-row pushes from overwriting a group.
public struct LiveActivityGroupClient: Sendable {
    private let transport: SyncTransport
    private let token: String
    public init(credentials: ViewerCredentials) throws {
        transport = try SyncTransport(baseURL: credentials.endpoint); token = credentials.token
    }
    init(transport: SyncTransport, token: String) { self.transport = transport; self.token = token }

    public func displayState() async throws -> ActivityDisplayState {
        let (data, _) = try await transport.request(path: "/v2/activity-display", token: token)
        let value = try JSONDecoder().decode(ActivityDisplayState.self, from: data)
        guard Self.validRevision(value.displayRevision) else { throw TransportError.malformed }
        return value
    }

    public func stop(expectedDisplayRevision: Int64, commandID: String, abandon: Bool = false) async throws -> ActivityGroupReceipt {
        guard Self.validRevision(expectedDisplayRevision), Self.validID(commandID) else { throw SyncError.configuration }
        let body = try JSONSerialization.data(withJSONObject: [
            "expectedDisplayRevision": expectedDisplayRevision, "commandId": commandID, "action": abandon ? "abandon" : "stop"
        ])
        let (data, _) = try await transport.request(path: "/v2/activity-display", method: "PUT", token: token, body: body)
        let value = try Self.receipt(data)
        guard value.stopped, value.groupId == nil else { throw TransportError.malformed }
        return value
    }

    public func register(groupID: String, expectedDisplayRevision: Int64, expectedRegistrationRevision: Int64,
                         commandID: String, windowIDs: [String], sourceDeviceID: String, sourceEpoch: String,
                         pushToken: Data, environment: APNSEnvironment, endsAt: Date, consent: Bool,
                         now: Date = .now) async throws -> ActivityGroupReceipt {
        guard consent, Self.validID(groupID), Self.validID(commandID), Self.validID(sourceDeviceID), Self.validID(sourceEpoch),
              (1...2).contains(windowIDs.count), Set(windowIDs).count == windowIDs.count, windowIDs.allSatisfy(Self.validID),
              Self.validRevision(expectedDisplayRevision), Self.validRevision(expectedRegistrationRevision),
              !pushToken.isEmpty, pushToken.count <= 512, endsAt > now, endsAt <= now.addingTimeInterval(8 * 60 * 60) else { throw SyncError.configuration }
        let body = try JSONSerialization.data(withJSONObject: [
            "expectedDisplayRevision": expectedDisplayRevision, "expectedRegistrationRevision": expectedRegistrationRevision,
            "commandId": commandID, "windowIds": windowIDs, "sourceDeviceId": sourceDeviceID, "sourceEpoch": sourceEpoch,
            "activityToken": pushToken.map { String(format: "%02x", $0) }.joined(), "environment": environment.rawValue,
            "endsAt": Self.timestamp(endsAt), "coverageExpiresAt": Self.timestamp(min(endsAt, now.addingTimeInterval(4 * 60 * 60))),
            "projectionConsent": true
        ])
        let (data, _) = try await transport.request(path: "/v2/activities/" + groupID, method: "PUT", token: token, body: body)
        let value = try Self.receipt(data)
        guard !value.stopped, value.groupId == groupID, let revision = value.registrationRevision,
              revision > 0, Self.validRevision(revision) else { throw TransportError.malformed }
        return value
    }

    public func end(groupID: String) async throws {
        guard Self.validID(groupID) else { throw SyncError.configuration }
        do {
            let (data, _) = try await transport.request(path: "/v2/activities/" + groupID, method: "DELETE", token: token)
            guard (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else { throw TransportError.malformed }
        } catch TransportError.rejected(404) { /* Cleanup is idempotent, not a Stop fence. */ }
    }

    private static func receipt(_ data: Data) throws -> ActivityGroupReceipt {
        let value = try JSONDecoder().decode(ActivityGroupReceipt.self, from: data)
        guard value.ok, validRevision(value.displayRevision) else { throw TransportError.malformed }
        return value
    }
    private static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }
    private static func validRevision(_ value: Int64) -> Bool { (0...9_007_199_254_740_991).contains(value) }
    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
}
