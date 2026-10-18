import Foundation
import QuotaCore

/// The self-serve v1 billing API reports daily contracted usage cost, not
/// fixed subscription fees. Unlike v2, these cost fields are populated.
enum CloudflareUsageReader {
    private struct Envelope: Decodable {
        struct Row: Decodable {
            let BillingAccountId, BillingCurrency, BillingPeriodStart: String
            let ContractedCost: Decimal
        }
        let success: Bool
        let result: [Row]
    }
    static func requestURL(accountID: String) throws -> URL {
        guard accountID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw ProviderFailure.parseChanged }
        return URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/billable-usage")!
    }
    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey, let account = credential.organizationID else { throw ProviderFailure.authRequired }
        let response = try await NativeHTTP.request("GET", requestURL(accountID: account),
            headers: ["Authorization": "Bearer " + credential.value.trimmingCharacters(in: .whitespacesAndNewlines)])
        return try parse(response.data, accountID: account)
    }
    static func parse(_ data: Data, accountID: String, now: Date = Date()) throws -> NativeUsage {
        _ = try requestURL(accountID: accountID)
        let envelope = try NativeHTTP.decode(Envelope.self, from: data)
        guard envelope.success else { throw ProviderFailure.parseChanged }
        guard let first = envelope.result.first else { throw ProviderFailure.unsupported }
        guard let start = QuotaRules.date(first.BillingPeriodStart), start <= now,
              first.BillingCurrency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw ProviderFailure.parseChanged }
        var sum = Decimal.zero
        for row in envelope.result {
            // Never aggregate another account, currency or subscription cycle.
            guard row.BillingAccountId.lowercased() == accountID.lowercased(),
                  row.BillingCurrency == first.BillingCurrency,
                  QuotaRules.date(row.BillingPeriodStart) == start,
                  !row.ContractedCost.isNaN, row.ContractedCost >= 0 else { throw ProviderFailure.parseChanged }
            sum += row.ContractedCost
        }
        let used = NSDecimalNumber(decimal: sum).doubleValue
        guard used.isFinite else { throw ProviderFailure.parseChanged }
        return NativeUsage(cost: .init(used: used, limit: 0, balance: nil,
            currency: first.BillingCurrency, period: "Current billing period usage", reportsSpend: true,
            startsAt: start, periodID: "cf-" + String(Int(start.timeIntervalSince1970))),
            identity: .init(accountID: accountID.lowercased()), updatedAt: now)
    }
}
