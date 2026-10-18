import Foundation
import CryptoKit

public struct ResetReminderSettings: Codable, Equatable, Sendable {
    public static let leadChoices = [5, 15, 30, 60]
    public var enabled: Bool
    public var leadMinutes: Int
    public init(enabled: Bool = false, leadMinutes: Int = 15) {
        self.enabled = enabled
        self.leadMinutes = Self.leadChoices.contains(leadMinutes) ? leadMinutes : 15
    }
    public var isValid: Bool { Self.leadChoices.contains(leadMinutes) }
}

/// A forecast, not evidence that a provider replenished its quota. Identity and
/// timestamps are canonical; user aliases and snapshot sequence do not affect it.
public struct ResetReminderRequest: Equatable, Sendable {
    public let id, cycleID, accountKey, windowKey: String
    public let resetsAt, fireAt, observedAt: Date
    public let providerName, accountAlias, windowName: String
    public var title: String { L("resetReminder.notification.title", providerName) }
    public var body: String {
        L("resetReminder.notification.body", accountAlias, windowName,
          resetsAt.formatted(date: .abbreviated, time: .shortened))
    }
}

public enum ResetReminderPolicy {
    public static let prefix = "ammo-reset-v1-"
    public static let maximumPending = 48
    /// Conservative app budget shared with other local notification features.
    public static let maximumTotalPending = 64
    public static func digest(_ components: [String]) -> String {
        // JSON array framing avoids delimiter collisions between opaque IDs.
        let data = try! JSONEncoder().encode(components)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func scope(_ snapshot: Snapshot) -> String { digest([snapshot.sourceDeviceId, snapshot.sourceEpoch]) }
    public static func accountKey(providerID: String, accountID: String) -> String { digest([providerID, accountID]) }
    public static func windowKey(snapshot: Snapshot, window: QuotaWindow) -> String {
        digest([snapshot.sourceDeviceId, snapshot.sourceEpoch, window.providerId, window.accountId, window.quotaKey, window.id])
    }
    public static func preservesForecast(_ window: QuotaWindow, now: Date) -> Bool {
        guard window.fetchOutcome != .authRequired, window.fetchOutcome != .disabled, window.availability == .available else { return false }
        return window.fetchOutcome != .ok || window.observedAt.flatMap(QuotaRules.date) == nil ||
            (window.staleAt.flatMap(QuotaRules.date).map { $0 <= now } ?? true)
    }
    public static func requests(snapshot: Snapshot, settings: ResetReminderSettings, now: Date, clockOffset: TimeInterval = 0) -> [ResetReminderRequest] {
        guard settings.enabled, settings.isValid, abs(clockOffset) <= 120 else { return [] }
        return snapshot.windows.compactMap { q -> ResetReminderRequest? in
            guard q.fetchOutcome == .ok, q.quality == .reported, q.availability == .available,
                  !q.isResetCardWindow, !q.isConsumptionMetric,
                  let observed = q.observedAt.flatMap(QuotaRules.date), observed <= now.addingTimeInterval(120),
                  let stale = q.staleAt.flatMap(QuotaRules.date), stale > now,
                  let reset = q.window.resetsAt.flatMap(QuotaRules.date), reset > now else { return nil }
            let fire = reset.addingTimeInterval(-TimeInterval(settings.leadMinutes * 60))
            guard fire > now else { return nil } // Never deliver missed forecasts as catch-up alerts.
            let identity = [snapshot.sourceDeviceId, snapshot.sourceEpoch, q.providerId, q.accountId, q.quotaKey, q.id,
                            String(reset.timeIntervalSince1970)]
            return ResetReminderRequest(id: prefix + digest(identity + [String(settings.leadMinutes)]),
                cycleID: digest(identity), accountKey: accountKey(providerID: q.providerId, accountID: q.accountId),
                windowKey: windowKey(snapshot: snapshot, window: q), resetsAt: reset, fireAt: fire, observedAt: observed,
                providerName: ProviderCatalog.identity(for: q.providerId).displayName,
                accountAlias: q.accountAlias, windowName: q.shortDisplayName)
        }.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }
    }

    public static func utcComponents(for date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }
}
