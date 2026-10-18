import Foundation
import QuotaCore

/// Provider-reported usage in a provider-neutral shape, produced by the
/// self-developed API clients and consumed by `NativeProviderNormalizer`.
public struct NativeUsage: Sendable {
    /// An integer counter rendered as an amount (count + unit) instead of a
    /// percent, e.g. the number of available quota-reset cards.
    public struct AmountWindow: Sendable {
        public let unit: QuotaWindow.Unit
        public let value: Int
        public init(unit: QuotaWindow.Unit, value: Int) {
            self.unit = unit
            self.value = value
        }
    }

    public struct Window: Sendable {
        /// Bucket key as the provider names it; primary/secondary use
        /// "primary"/"secondary", extras carry their API identifier.
        public let id: String
        public let usedPercent: Double
        public let windowMinutes: Int?
        public let resetsAt: Date?
        public var amountWindow: AmountWindow?
        public init(id: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil,
                    amountWindow: AmountWindow? = nil) {
            self.id = id
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
            self.amountWindow = amountWindow
        }
    }

    public struct Cost: Sendable {
        public let used: Double
        public let reportsSpend: Bool
        public let startsAt: Date?
        public let periodID: String?
        /// Zero means the provider reports no matching budget.
        public let limit: Double
        /// Nil when the provider does not report a prepaid balance.
        public let balance: Double?
        /// Gifted credit the provider folds into its headline balance (e.g.
        /// Amp Free); kept separate so purchased and free credit stay distinct.
        public let freeBalance: Double?
        public let freeResetsAt: Date?
        public let currency: String
        public let period: String
        public let resetsAt: Date?
        public init(used: Double, limit: Double, balance: Double?, currency: String, period: String,
                    resetsAt: Date? = nil, freeBalance: Double? = nil, freeResetsAt: Date? = nil, reportsSpend: Bool = false, startsAt: Date? = nil, periodID: String? = nil) {
            self.used = used
            self.reportsSpend = reportsSpend
            self.startsAt = startsAt
            self.periodID = periodID
            self.limit = limit
            self.balance = balance
            self.freeBalance = freeBalance
            self.freeResetsAt = freeResetsAt
            self.currency = currency
            self.period = period
            self.resetsAt = resetsAt
        }
    }

    public struct Identity: Sendable {
        public let accountID: String?
        public let email: String?
        public let organization: String?
        public init(accountID: String? = nil, email: String? = nil, organization: String? = nil) {
            self.accountID = accountID
            self.email = email
            self.organization = organization
        }
    }

    public enum Confidence: Sendable {
        case reported
        case estimated
    }

    public var primary: Window?
    public var secondary: Window?
    public var tertiary: Window?
    public var extraWindows: [Window]
    public var cost: Cost?
    public var identity: Identity
    /// One-way account/source-scoped evidence used only when the provider
    /// response carries no self-reported account identifier.
    public var identitySeed: String?
    public let confidence: Confidence
    public let updatedAt: Date

    public init(
        primary: Window? = nil,
        secondary: Window? = nil,
        tertiary: Window? = nil,
        extraWindows: [Window] = [],
        cost: Cost? = nil,
        identity: Identity = .init(),
        identitySeed: String? = nil,
        confidence: Confidence = .reported,
        updatedAt: Date = Date())
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraWindows = extraWindows
        self.cost = cost
        self.identity = identity
        self.identitySeed = identitySeed
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}
