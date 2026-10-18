import Foundation

/// Presentation categories describe metrics, never a provider's entire account.
public enum QuotaCategory: String, CaseIterable, Sendable, Identifiable {
    case all, balance, spend, allowance, quota
    public var id: String { rawValue }
    public var title: String {
        let key = "billing.category." + rawValue
        return L(key)
    }
    public func includes(_ window: QuotaWindow) -> Bool { self == .all || self == window.category }
}

public extension QuotaWindow {
    var category: QuotaCategory {
        if isConsumptionMetric { return .spend }
        if quotaKey == "free-balance" { return .allowance }
        if unit == .money && remainingBps == nil { return .balance }
        return .quota
    }
}

public struct BillingRule: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case lowBalance, budget, quota }
    public let windowID: String
    public let kind: Kind
    public let currency: String?
    /// Decimal strings in the metric currency; quota thresholds are percentages.
    public var warning: String
    public var critical: String
    public var enabled: Bool
    public var id: String { windowID }

    public init(windowID: String, kind: Kind, currency: String?, warning: String, critical: String, enabled: Bool = true) {
        self.windowID = windowID; self.kind = kind; self.currency = currency
        self.warning = warning; self.critical = critical; self.enabled = enabled
    }
    public var isValid: Bool {
        guard let warningValue = Self.number(warning), let criticalValue = Self.number(critical),
              !windowID.isEmpty, warningValue >= 0, criticalValue >= 0 else { return false }
        switch kind {
        case .budget: return currency != nil && criticalValue > 0 && warningValue > 0 && warningValue < criticalValue
        case .lowBalance: return currency != nil && warningValue > criticalValue
        case .quota: return currency == nil && warningValue > criticalValue && warningValue <= 100
        }
    }
    public static func number(_ value: String) -> Decimal? {
        guard value.utf8.count <= 48, value.range(of: "^(0|[1-9][0-9]*)(\\.[0-9]{1,12})?$", options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func suggested(for window: QuotaWindow) -> BillingRule? {
        if window.category == .spend {
            return .init(windowID: window.id, kind: .budget, currency: window.currency, warning: "80", critical: "100")
        }
        if window.unit == .money && window.remainingBps == nil {
            return .init(windowID: window.id, kind: .lowBalance, currency: window.currency, warning: "10", critical: "3")
        }
        if window.remainingBps != nil {
            return .init(windowID: window.id, kind: .quota, currency: nil, warning: "20", critical: "5")
        }
        return nil
    }
    public func value(for window: QuotaWindow, now: Date) -> Decimal? {
        guard isValid, enabled, window.id == windowID, window.fetchOutcome == .ok,
              window.availability == .available, window.quality == .reported,
              let observed = window.observedAt.flatMap(QuotaRules.date), observed <= now.addingTimeInterval(120),
              let stale = window.staleAt.flatMap(QuotaRules.date), stale > now,
              window.window.resetsAt.flatMap(QuotaRules.date).map({ $0 > now }) ?? true else { return nil }
        switch kind {
        case .budget:
            guard window.isConsumptionMetric, window.currency == currency else { return nil }
            return window.amount.flatMap(Self.number)
        case .lowBalance:
            guard window.unit == .money, !window.isConsumptionMetric, window.remainingBps == nil,
                  window.currency == currency else { return nil }
            return window.amount.flatMap(Self.number)
        case .quota:
            return window.remainingBps.map { Decimal($0) / 100 }
        }
    }
    public func severity(for value: Decimal) -> BillingSeverity {
        guard let warning = Self.number(warning), let critical = Self.number(critical), isValid else { return .normal }
        if kind == .budget { return value >= critical ? .critical : value >= warning ? .warning : .normal }
        return value <= critical ? .critical : value <= warning ? .warning : .normal
    }
}

public enum BillingSeverity: Int, Codable, Sendable, Comparable {
    case normal, warning, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Persisted before delivery. Retained/failed/out-of-order observations never rearm alerts.
public struct BillingAlertLedger: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var severity: BillingSeverity
        public var observedAt: String
        public var period: String?
        public var periodStart: String?
    }
    public private(set) var entries: [String: Entry] = [:]
    public init() {}
    public mutating func reset(_ windowID: String) { entries.removeValue(forKey: windowID) }
    public mutating func evaluate(_ rule: BillingRule, window: QuotaWindow, now: Date) -> BillingSeverity? {
        guard let value = rule.value(for: window, now: now), let observedAt = window.observedAt,
              let observed = QuotaRules.date(observedAt) else { return nil }
        let previous = entries[rule.id]
        if let old = previous, let oldDate = QuotaRules.date(old.observedAt), observed <= oldDate { return nil }
        let severity = rule.severity(for: value)
        let period = window.window.periodId ?? window.window.resetsAt
        // Fetch time does not establish billing-period order. A delayed response
        // may carry an older period despite having a newer observedAt.
        let periodStart = window.window.startsAt ?? window.window.resetsAt
        let start = periodStart.flatMap(QuotaRules.date)
        let oldStart = previous?.periodStart.flatMap(QuotaRules.date)
        if let oldStart {
            guard let start, start >= oldStart else { return nil }
        }
        let advanced = previous != nil && start != nil && oldStart != nil && start! > oldStart!
        entries[rule.id] = Entry(severity: severity, observedAt: observedAt, period: period, periodStart: periodStart)
        // Opaque period identifiers alone cannot safely rearm an alert.
        let oldSeverity = advanced ? .normal : previous?.severity ?? .normal
        return severity > oldSeverity ? severity : nil
    }
}
