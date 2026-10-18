import Foundation

/// Usage is observed work, never a remaining-quota percentage or a billing estimate.
public enum TokenUsageAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code", codex
}

public struct TokenUsageCounts: Codable, Equatable, Sendable {
    public let nonCachedInput, cacheRead, cacheWrite, output: Int64
    public init(nonCachedInput: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0) {
        self.nonCachedInput = nonCachedInput; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.output = output
    }
    public static let zero = TokenUsageCounts()
    public var total: Int64 { nonCachedInput + cacheRead + cacheWrite + output }
    public var isValid: Bool {
        let values = [nonCachedInput, cacheRead, cacheWrite, output]
        return values.allSatisfy { (0...2_251_799_813_685_247).contains($0) }
    }
    public func adding(_ other: Self) -> Self? {
        guard isValid, other.isValid else { return nil }
        let result = Self(nonCachedInput: nonCachedInput + other.nonCachedInput,
                          cacheRead: cacheRead + other.cacheRead, cacheWrite: cacheWrite + other.cacheWrite,
                          output: output + other.output)
        return result.isValid ? result : nil
    }
}

public struct TokenUsageSource: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case available, partial, unavailable, disabled }
    public let agent: TokenUsageAgent
    public let status: Status
    public let scannedAt, latestEventAt, diagnostic: String?
    public init(agent: TokenUsageAgent, status: Status, scannedAt: String? = nil,
                latestEventAt: String? = nil, diagnostic: String? = nil) {
        self.agent = agent; self.status = status; self.scannedAt = scannedAt
        self.latestEventAt = latestEventAt; self.diagnostic = diagnostic
    }
}

public struct TokenUsageBucket: Codable, Equatable, Sendable {
    public let day: String
    public let agent: TokenUsageAgent
    public let tokens: TokenUsageCounts
    public init(day: String, agent: TokenUsageAgent, tokens: TokenUsageCounts) {
        self.day = day; self.agent = agent; self.tokens = tokens
    }
}

/// A bounded replacement snapshot from one Mac. It is not an append-only ledger.
/// No account, project, conversation, model, request IDs or raw log text cross sync.
public struct TokenUsageSnapshot: Codable, Sendable {
    public let schemaVersion, sourceDeviceId, sourceEpoch: String
    public let sourceSequence: Int64
    public let capturedAt, timeZoneIdentifier, retainedFromDay: String
    public let sources: [TokenUsageSource]
    public let buckets: [TokenUsageBucket]
    public init(schemaVersion: String = "1.0.0", sourceDeviceId: String, sourceEpoch: String,
                sourceSequence: Int64, capturedAt: String, timeZoneIdentifier: String,
                retainedFromDay: String, sources: [TokenUsageSource], buckets: [TokenUsageBucket]) {
        self.schemaVersion = schemaVersion; self.sourceDeviceId = sourceDeviceId; self.sourceEpoch = sourceEpoch
        self.sourceSequence = sourceSequence; self.capturedAt = capturedAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.retainedFromDay = retainedFromDay; self.sources = sources; self.buckets = buckets
    }
    public var isDisabledObservation: Bool {
        buckets.isEmpty && Set(sources.map(\.agent)) == Set(TokenUsageAgent.allCases)
            && sources.allSatisfy { $0.status == .disabled }
    }
    public func rebased(deviceID: String, epoch: String, sequence: Int64) -> Self {
        Self(sourceDeviceId: deviceID, sourceEpoch: epoch, sourceSequence: sequence, capturedAt: capturedAt,
             timeZoneIdentifier: timeZoneIdentifier, retainedFromDay: retainedFromDay, sources: sources, buckets: buckets)
    }
}

public enum TokenUsageSnapshotCodec {
    public static let maxBytes = 131_072
    public static let maxBuckets = 800
    public static func encode(_ value: TokenUsageSnapshot) throws -> Data {
        let data = try JSONEncoder().encode(value)
        _ = try decode(data)
        return data
    }
    public static func decode(_ data: Data) throws -> TokenUsageSnapshot {
        guard data.count <= maxBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractError("Invalid usage snapshot size or object")
        }
        func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
            guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else {
                throw ContractError("Invalid usage fields")
            }
        }
        try keys(object, required: ["schemaVersion", "sourceDeviceId", "sourceEpoch", "sourceSequence", "capturedAt",
                                    "timeZoneIdentifier", "retainedFromDay", "sources", "buckets"])
        guard let sources = object["sources"] as? [[String: Any]], let buckets = object["buckets"] as? [[String: Any]] else {
            throw ContractError("Invalid usage arrays")
        }
        for source in sources {
            try keys(source, required: ["agent", "status"], optional: ["scannedAt", "latestEventAt", "diagnostic"])
            for key in ["scannedAt", "latestEventAt", "diagnostic"] where source[key] != nil {
                guard source[key] is String else { throw ContractError("Invalid nullable usage metadata") }
            }
        }
        for bucket in buckets {
            try keys(bucket, required: ["day", "agent", "tokens"])
            guard let tokens = bucket["tokens"] as? [String: Any] else { throw ContractError("Invalid usage tokens") }
            try keys(tokens, required: ["nonCachedInput", "cacheRead", "cacheWrite", "output"])
        }
        let value = try JSONDecoder().decode(TokenUsageSnapshot.self, from: data)
        func identity(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }
        func timestamp(_ value: String?) -> Bool { value == nil || value.flatMap(QuotaRules.date) != nil }
        guard value.schemaVersion == "1.0.0", identity(value.sourceDeviceId), identity(value.sourceEpoch),
              (1...9_007_199_254_740_991).contains(value.sourceSequence), QuotaRules.date(value.capturedAt) != nil,
              let zone = TimeZone(identifier: value.timeZoneIdentifier), TokenUsageCalendar.date(value.retainedFromDay, in: zone) != nil,
              value.sources.count <= 2, value.buckets.count <= maxBuckets,
              Set(value.sources.map(\.agent)).count == value.sources.count,
              Set(value.buckets.map { $0.day + "/" + $0.agent.rawValue }).count == value.buckets.count else {
            throw ContractError("Invalid usage metadata")
        }
        for source in value.sources {
            guard timestamp(source.scannedAt), timestamp(source.latestEventAt),
                  source.diagnostic.map({ $0.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil }) ?? true else {
                throw ContractError("Invalid usage source metadata")
            }
        }
        let sourceAgents = Set(value.sources.filter { $0.status == .available || $0.status == .partial }.map(\.agent))
        var aggregate = TokenUsageCounts.zero
        for bucket in value.buckets {
            guard let next = aggregate.adding(bucket.tokens) else { throw ContractError("Usage aggregate overflow") }
            aggregate = next
            guard bucket.tokens.isValid, TokenUsageCalendar.date(bucket.day, in: zone) != nil,
                  bucket.day >= value.retainedFromDay, sourceAgents.contains(bucket.agent) else {
                throw ContractError("Invalid usage bucket")
            }
        }
        return value
    }
}

public enum TokenUsagePeriod: String, CaseIterable, Sendable { case day, week, month, last7Days }
public enum TokenUsageCalendar {
    public static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    public static func day(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter(); f.calendar = calendar(in: zone); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func date(_ text: String, in zone: TimeZone) -> Date? {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let f = DateFormatter(); f.calendar = calendar(in: zone); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: text), day(date, in: zone) == text else { return nil }; return date
    }
    public static func interval(_ period: TokenUsagePeriod, anchor: Date, in zone: TimeZone) -> DateInterval {
        let calendar = calendar(in: zone)
        if period == .last7Days {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor))!
            return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: end)!, end: end)
        }
        return calendar.dateInterval(of: period == .day ? .day : period == .week ? .weekOfYear : .month, for: anchor)!
    }
}

public struct TokenUsageSummary: Sendable {
    public let start, end: Date
    public let total: TokenUsageCounts?
    public let byAgent: [TokenUsageAgent: TokenUsageCounts]
    public let daily: [TokenUsageBucket]
    public let isPartial: Bool
    public let sources: [TokenUsageSource]
    public static func make(snapshot: TokenUsageSnapshot?, period: TokenUsagePeriod, anchor: Date = Date(), timeZone: TimeZone) -> Self {
        let range = TokenUsageCalendar.interval(period, anchor: anchor, in: timeZone)
        guard let snapshot, snapshot.timeZoneIdentifier == timeZone.identifier else {
            return Self(start: range.start, end: range.end, total: nil, byAgent: [:], daily: [], isPartial: true, sources: [])
        }
        let start = TokenUsageCalendar.day(range.start, in: timeZone), end = TokenUsageCalendar.day(range.end, in: timeZone)
        let buckets = snapshot.buckets.filter { $0.day >= start && $0.day < end }
        let observed = snapshot.sources.filter { $0.status == .available || $0.status == .partial }
        var byAgent = Dictionary(uniqueKeysWithValues: observed.map { ($0.agent, TokenUsageCounts.zero) })
        var total = TokenUsageCounts.zero
        var valid = true
        for bucket in buckets {
            guard let agentSum = byAgent[bucket.agent]?.adding(bucket.tokens), let sum = total.adding(bucket.tokens) else { valid = false; break }
            byAgent[bucket.agent] = agentSum; total = sum
        }
        // Local logs are always partial coverage of provider/account activity.
        // A period outside retention is unknown rather than a misleading zero.
        let captured = QuotaRules.date(snapshot.capturedAt)
        let known = !observed.isEmpty && start >= snapshot.retainedFromDay && valid && captured.map { range.start <= $0 } == true
        return Self(start: range.start, end: range.end, total: known ? total : nil,
                    byAgent: known ? byAgent : [:], daily: known ? buckets : [], isPartial: true, sources: snapshot.sources)
    }
}
