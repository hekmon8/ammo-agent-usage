import Foundation

/// Local-only projection. Never added to the strict usage sync/receipt DTO.
public struct TokenUsageLocalAnalysis: Codable, Sendable {
    public let capturedAt, timeZoneIdentifier, priceVersion: String
    public let sources: [TokenUsageScanCoverage]
    public let costs: [TokenUsageCostBucket]
    public init(capturedAt: String, timeZoneIdentifier: String, sources: [TokenUsageScanCoverage], costs: [TokenUsageCostBucket]) {
        self.capturedAt = capturedAt; self.timeZoneIdentifier = timeZoneIdentifier
        priceVersion = TokenUsagePricing.version; self.sources = sources; self.costs = costs
    }
    public func isValid(for snapshot: TokenUsageSnapshot) -> Bool {
        guard capturedAt == snapshot.capturedAt, timeZoneIdentifier == snapshot.timeZoneIdentifier,
              priceVersion == TokenUsagePricing.version, sources.count <= 2, costs.count <= 800,
              Set(sources.map(\.agent)).count == sources.count,
              Set(costs.map { $0.day + "/" + $0.agent.rawValue }).count == costs.count else { return false }
        let totals = Dictionary(uniqueKeysWithValues: snapshot.buckets.map { ($0.day + "/" + $0.agent.rawValue, $0.tokens.total) })
        for cost in costs {
            guard cost.pricedTokens >= 0, cost.unpricedTokens >= 0,
                  cost.pricedTokens <= 9_007_199_254_740_988, cost.unpricedTokens <= 9_007_199_254_740_988,
                  cost.pricedTokens + cost.unpricedTokens == totals[cost.day + "/" + cost.agent.rawValue],
                  cost.standardUSD.map({ $0.isFinite && $0 >= 0 }) ?? (cost.pricedTokens == 0) else { return false }
        }
        return costs.count == snapshot.buckets.count && sources.allSatisfy {
            $0.discoveredFiles >= 0 && $0.discoveredFiles <= 10_000 && $0.readFiles >= 0 && $0.readFiles <= $0.discoveredFiles
                && $0.bytesRead >= 0 && $0.bytesRead <= $0.byteLimit && $0.byteLimit > 0
                && $0.reasons.count <= 32 && $0.reasons.values.allSatisfy { (0...10_000_000).contains($0) }
        }
    }
    public func summary(period: TokenUsagePeriod, anchor: Date, in zone: TimeZone) -> TokenUsageCostSummary? {
        guard zone.identifier == timeZoneIdentifier else { return nil }
        let range = TokenUsageCalendar.interval(period, anchor: anchor, in: zone)
        let start = TokenUsageCalendar.day(range.start, in: zone), end = TokenUsageCalendar.day(range.end, in: zone)
        let selected = costs.filter { $0.day >= start && $0.day < end }
        let priced = selected.reduce(Int64(0)) { $0 + $1.pricedTokens }
        let unknown = selected.reduce(Int64(0)) { $0 + $1.unpricedTokens }
        return TokenUsageCostSummary(standardUSD: priced > 0 ? selected.reduce(0) { $0 + ($1.standardUSD ?? 0) } : nil,
                                     pricedTokens: priced, unpricedTokens: unknown)
    }
}

public struct TokenUsageScanCoverage: Codable, Sendable {
    public let agent: TokenUsageAgent
    public let discoveredFiles, readFiles, bytesRead, byteLimit: Int
    public let reasons: [String: Int]
    public let reusedUnchangedFiles: Bool
    public init(agent: TokenUsageAgent, discoveredFiles: Int, readFiles: Int, bytesRead: Int, byteLimit: Int, reasons: [String: Int], reusedUnchangedFiles: Bool = false) {
        self.agent = agent; self.discoveredFiles = discoveredFiles; self.readFiles = readFiles
        self.bytesRead = bytesRead; self.byteLimit = byteLimit; self.reasons = reasons
        self.reusedUnchangedFiles = reusedUnchangedFiles
    }
}
public struct TokenUsageCostBucket: Codable, Sendable {
    public let day: String
    public let agent: TokenUsageAgent
    public let standardUSD: Double?
    public let pricedTokens, unpricedTokens: Int64
    public init(day: String, agent: TokenUsageAgent, standardUSD: Double?, pricedTokens: Int64, unpricedTokens: Int64) {
        self.day = day; self.agent = agent; self.standardUSD = standardUSD
        self.pricedTokens = pricedTokens; self.unpricedTokens = unpricedTokens
    }
}
public struct TokenUsageCostSummary: Sendable {
    public let standardUSD: Double?
    public let pricedTokens, unpricedTokens: Int64
    public var pricedFraction: Double? {
        let total = pricedTokens + unpricedTokens
        return total > 0 ? Double(pricedTokens) / Double(total) : nil
    }
}

/// USD / million tokens, official first-party standard rates verified 2026-10-07.
/// This values observed tokens at Standard prices; it is not an invoice or a
/// subscription charge. No Fast/Batch/region assumptions or model fallback.
public enum TokenUsagePricing {
    public static let version = "2026-10-07"
    public static let openAISource = URL(string: "https://developers.openai.com/api/docs/pricing")!
    public static let claudeSource = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    public struct Rate: Sendable {
        public let input, cacheRead, cacheWrite, output: Double
        public let longContextThreshold: Int64?
        public init(input: Double, cacheRead: Double, cacheWrite: Double, output: Double, longContextThreshold: Int64? = nil) {
            self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
            self.longContextThreshold = longContextThreshold
        }
    }
    public static func rate(agent: TokenUsageAgent, model: String?) -> Rate? {
        guard let model else { return nil }
        switch (agent, model) {
        case (.codex, "gpt-6-astra"): return Rate(input: 10, cacheRead: 1, cacheWrite: 12.5, output: 50, longContextThreshold: 272_000)
        case (.codex, "gpt-6.1-sol"): return Rate(input: 2, cacheRead: 0.1, cacheWrite: 2.5, output: 10, longContextThreshold: 272_000)
        case (.codex, "gpt-6-luna"): return Rate(input: 0.1, cacheRead: 0.01, cacheWrite: 0.125, output: 0.5, longContextThreshold: 272_000)
        case (.codex, "gpt-6-sol"): return Rate(input: 2, cacheRead: 0.2, cacheWrite: 2.5, output: 10, longContextThreshold: 272_000)
        case (.codex, "gpt-5.6-sol"): return Rate(input: 4, cacheRead: 0.4, cacheWrite: 5, output: 20, longContextThreshold: 272_000)
        case (.codex, "gpt-5.6-terra"): return Rate(input: 2, cacheRead: 0.2, cacheWrite: 2.5, output: 12, longContextThreshold: 272_000)
        case (.claudeCode, "claude-opus-4-6"), (.claudeCode, "claude-opus-4-7"), (.claudeCode, "claude-opus-4-8"), (.claudeCode, "claude-opus-5"):
            return Rate(input: 5, cacheRead: 0.5, cacheWrite: 6.25, output: 25)
        case (.claudeCode, "claude-opus-5-5"): return Rate(input: 4, cacheRead: 0.2, cacheWrite: 5, output: 20)
        case (.claudeCode, "claude-sonnet-4-6"): return Rate(input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15)
        case (.claudeCode, "claude-sonnet-5"), (.claudeCode, "claude-sonnet-5-5"):
            return Rate(input: 2, cacheRead: 0.2, cacheWrite: 2.5, output: 10)
        case (.claudeCode, "claude-haiku-4-5"): return Rate(input: 1, cacheRead: 0.1, cacheWrite: 1.25, output: 5)
        default: return nil
        }
    }
    public static func standardUSD(agent: TokenUsageAgent, model: String?, counts: TokenUsageCounts,
                                   requestInput: Int64?, cacheWriteOneHour: Int64? = nil) -> Double? {
        guard counts.isValid, let rate = rate(agent: agent, model: model) else { return nil }
        var inputMultiplier = 1.0, outputMultiplier = 1.0
        if let threshold = rate.longContextThreshold {
            guard let requestInput, requestInput >= 0 else { return nil }
            if requestInput > threshold { inputMultiplier = 2; outputMultiplier = 1.5 }
        }
        var writeCost = Double(counts.cacheWrite) * rate.cacheWrite
        if agent == .claudeCode, counts.cacheWrite > 0 {
            // Missing cache TTL must not silently become the cheaper 5m rate.
            guard let hour = cacheWriteOneHour, (0...counts.cacheWrite).contains(hour) else { return nil }
            writeCost = Double(counts.cacheWrite - hour) * rate.cacheWrite + Double(hour) * rate.input * 2
        }
        return (Double(counts.nonCachedInput) * rate.input * inputMultiplier
            + Double(counts.cacheRead) * rate.cacheRead * inputMultiplier
            + writeCost * inputMultiplier + Double(counts.output) * rate.output * outputMultiplier) / 1_000_000
    }
}
