import Foundation

// Wire DTOs from contracts/snapshot.schema.json; decode through SnapshotCodec.
public enum Availability: String, Codable, Sendable { case available, unavailable, unlimited }
public enum FetchOutcome: String, Codable, Sendable {
    case ok, error, throttled, disabled
    case authRequired = "auth_required"
}
public enum SourceMethod: String, Codable, Sendable {
    case officialAPI = "official_api", localRPC = "local_rpc", localFile = "local_file"
    case communityEndpoint = "community_endpoint", userDefined = "user_defined"
}
public struct WindowDefinition: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case rolling, fixed, calendar, unknown }
    public let kind: Kind
    public let durationSeconds: Int?
    public let startsAt: String?
    public let resetsAt: String?
    public let periodId: String?
}
public struct HistoryPoint: Codable, Sendable {
    public let observedAt: String
    public let remainingBps: Int?
    public let segmentId: String
}
public struct QuotaWindow: Codable, Sendable {
    public enum Unit: String, Codable, Sendable { case percent, tokens, requests, credits, money }
    public enum Quality: String, Codable, Sendable { case reported, estimated, unknown }
    public let id, providerId, accountId, accountAlias, quotaKey: String
    public let sharedPoolId: String?
    public let unit: Unit
    public let currency: String?
    public let availability: Availability
    public let remainingBps: Int?
    public let amount, limit: String?
    public let quality: Quality
    public let sourceMethod: SourceMethod
    public let fetchOutcome: FetchOutcome
    public let observedAt, staleAt: String?
    public let window: WindowDefinition
    public let history: [HistoryPoint]
}
public struct Snapshot: Codable, Sendable {
    public let schemaVersion, snapshotId, sourceDeviceId, sourceEpoch: String
    public let sourceSequence: Int64
    public let capturedAt: String
    public let windows: [QuotaWindow]
}
// Required-but-nullable JSON fields must be encoded explicitly (encodeIfPresent
// would omit them and violate the strict wire schema). Decoding remains Codable.
extension WindowDefinition {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(startsAt, forKey: .startsAt)
        try c.encode(resetsAt, forKey: .resetsAt)
        try c.encode(periodId, forKey: .periodId)
    }
}
extension HistoryPoint {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(remainingBps, forKey: .remainingBps)
        try c.encode(segmentId, forKey: .segmentId)
    }
}
extension QuotaWindow {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(accountAlias, forKey: .accountAlias)
        try c.encode(quotaKey, forKey: .quotaKey)
        try c.encode(sharedPoolId, forKey: .sharedPoolId)
        try c.encode(unit, forKey: .unit)
        try c.encode(currency, forKey: .currency)
        try c.encode(availability, forKey: .availability)
        try c.encode(remainingBps, forKey: .remainingBps)
        try c.encode(amount, forKey: .amount)
        try c.encode(limit, forKey: .limit)
        try c.encode(quality, forKey: .quality)
        try c.encode(sourceMethod, forKey: .sourceMethod)
        try c.encode(fetchOutcome, forKey: .fetchOutcome)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(staleAt, forKey: .staleAt)
        try c.encode(window, forKey: .window)
        try c.encode(history, forKey: .history)
    }
}
