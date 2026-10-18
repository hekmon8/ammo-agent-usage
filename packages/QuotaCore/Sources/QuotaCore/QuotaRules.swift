import Foundation

public enum DisplayState: String, Sendable {
    case fresh, low, exhausted, stale, resetPending, unavailable, unlimited, authRequired, offline, locked, clockSkew
}

public enum QuotaRules {
    private static let dateParser = QuotaDateParser()
    public static func date(_ string: String) -> Date? {
        dateParser.parse(string)
    }

    public static func remainingBps(usedPercent: String) throws -> Int {
        guard usedPercent.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: usedPercent, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0, value <= 100 else { throw ContractError("Invalid used percentage") }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return 10_000 - NSDecimalNumber(decimal: rounded).intValue
    }

    public static func state(_ q: QuotaWindow, now: Date, locked: Bool = false, clockOffset: TimeInterval = 0) -> DisplayState {
        if locked { return .locked }
        if q.fetchOutcome == .authRequired { return .authRequired }
        if q.availability == .unavailable { return .unavailable }
        if abs(clockOffset) > 120 || q.observedAt.flatMap(date).map({ $0.timeIntervalSince(now) > 120 }) == true { return .clockSkew }
        if let reset = q.window.resetsAt.flatMap(date), reset <= now,
           q.observedAt.flatMap(date).map({ $0 < reset }) ?? true {
            return q.isResetCardWindow ? .stale : .resetPending
        }
        if q.staleAt.flatMap(date).map({ $0 <= now }) ?? true { return .stale }
        if q.availability == .unlimited { return .unlimited }
        if !q.isConsumptionMetric && (q.remainingBps == 0 || (q.remainingBps == nil && q.amount.flatMap { Decimal(string: $0) } == 0)) { return .exhausted }
        if let bps = q.remainingBps, bps <= 1_000 { return .low }
        return .fresh
    }

    public static func trendSegments(_ points: [HistoryPoint], interval: TimeInterval = 300) -> [[HistoryPoint]] {
        var segments: [[HistoryPoint]] = [], current: [HistoryPoint] = []
        var previous: HistoryPoint?
        for point in points {
            guard point.remainingBps != nil, let time = date(point.observedAt) else {
                if !current.isEmpty { segments.append(current) }; current = []; previous = nil; continue
            }
            if let p = previous, let previousTime = date(p.observedAt) {
                let delta = time.timeIntervalSince(previousTime)
                if p.segmentId != point.segmentId || delta <= 0 || delta > interval * 2 {
                    if !current.isEmpty { segments.append(current) }; current = []
                }
            }
            current.append(point); previous = point
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}

public struct QuotaPresentation: Sendable {
    public let window: QuotaWindow
    public let state: DisplayState
    public let offline: Bool
    public init(window: QuotaWindow, now: Date, offline: Bool = false, locked: Bool = false, clockOffset: TimeInterval = 0) {
        self.window = window; self.offline = offline
        state = QuotaRules.state(window, now: now, locked: locked, clockOffset: clockOffset)
    }
    public var isHistorical: Bool { offline || window.fetchOutcome != .ok || [.stale, .resetPending, .clockSkew].contains(state) }
    public var visibleBps: Int? { [.locked, .unavailable].contains(state) ? nil : window.remainingBps }
    public var valueHeading: String {
        let label = window.isConsumptionMetric ? L("quota.heading.spent") : L("quota.heading.remaining")
        return isHistorical ? L("quota.heading.lastRecorded", label) : label
    }
    public var number: String {
        if [.locked, .unavailable].contains(state) { return "—" }
        if window.availability == .unlimited { return L("quota.status.unlimited") }
        if let bps = visibleBps { return String(format: "%.2f", Double(bps) / 100).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + "%" }
        if let amount = window.amount {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = window.unit == .tokens || window.unit == .requests ? 0 : 2
            formatter.minimumFractionDigits = window.unit == .money ? 2 : 0
            formatter.roundingMode = .down
            let formatted = formatter.string(from: NSDecimalNumber(string: amount)) ?? amount
            // A reset-card count reads "1 reset / 2 resets", not the generic
            // request unit, so English never renders "1 requests".
            if window.unit == .requests, window.isResetCardWindow {
                return formatted + " " + (Int(amount) == 1 ? L("quota.unit.resetOne") : L("quota.unit.resets"))
            }
            let unit: String = switch window.unit {
            case .credits: L("quota.unit.credits")
            case .requests: L("quota.unit.requests")
            case .tokens: "Token"
            default: window.currency ?? window.unit.rawValue
            }
            return formatted + " " + unit
        }
        return "—"
    }
    public var status: String {
        (offline ? L("quota.status.offlinePrefix") : "") + baseStatus + qualityStatus
    }
    private var qualityStatus: String {
        switch window.quality {
        case .reported: return ""
        case .estimated: return " · " + L("quota.quality.estimated")
        case .unknown: return " · " + L("quota.quality.unverifiedSource")
        }
    }
    private var baseStatus: String {
        switch state {
        case .fresh: return isHistorical ? L("quota.status.lastRecorded") : L("quota.status.updated")
        case .low: return isHistorical ? L("quota.status.lastRecordedLow") : L("quota.status.low")
        case .exhausted: return isHistorical ? L("quota.status.lastRecordedAtLimit") : L("quota.status.atLimit")
        case .stale: return L("quota.status.stale")
        case .resetPending: return L("quota.status.resetPending")
        case .unavailable: return L("quota.status.unknown")
        case .unlimited: return isHistorical ? L("quota.status.lastRecordedUnlimited") : L("quota.status.unlimited")
        case .authRequired: return L("quota.status.authRequired")
        case .offline: return L("quota.status.offline")
        case .locked: return L("quota.status.locked")
        case .clockSkew: return L("quota.status.clockSkew")
        }
    }
    public var activeTicks: Int { (visibleBps ?? 0) / 200 }
}

/// Formatter state is protected by the lock; cached timestamps are immutable.
/// Cache only dates, never time-dependent display states (stale/reset/clock skew).
private final class QuotaDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    private let cache = NSCache<NSString, NSDate>()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        cache.countLimit = 4096
    }

    func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let key = string as NSString
        if let date = cache.object(forKey: key) { return date as Date }
        guard let date = fractional.date(from: string) ?? whole.date(from: string) else { return nil }
        cache.setObject(date as NSDate, forKey: key)
        return date
    }
}
