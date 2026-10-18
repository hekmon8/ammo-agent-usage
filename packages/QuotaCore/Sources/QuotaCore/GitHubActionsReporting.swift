import Foundation

/// A UTC query month, not a provider-reported billing-cycle reset date.
public enum GitHubActionsReporting {
    public static func queryMonth(_ window: QuotaWindow) -> String? {
        guard window.providerId == "github-actions", window.isConsumptionMetric,
              let period = window.window.periodId,
              period.range(of: "^github-actions-(user|organization)-[0-9]{4}-(0[1-9]|1[0-2])$",
                           options: .regularExpression) != nil else { return nil }
        return String(period.suffix(7))
    }
}
