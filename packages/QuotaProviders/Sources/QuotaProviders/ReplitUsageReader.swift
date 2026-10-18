import Foundation
import QuotaCore

/// Enterprise Admin API only. Gross ledger cost before credit/discount/invoice
/// adjustments must never be labelled prepaid balance or final invoice amount.
enum ReplitUsageReader {
    private struct Envelope: Decodable {
        struct Usage: Decodable {
            struct Interval: Decodable { let startTime, endTime: String }
            let interval: Interval
            let currency: String
            let totalCostUsd: Double
        }
        let data: Usage
    }
    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        let key = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.kind == .apiKey, key.hasPrefix("rpl_") else { throw ProviderFailure.authRequired }
        let response = try await NativeHTTP.request("GET", URL(string: "https://api.replit.com/v1/usage?billingPeriod=current")!,
            headers: ["Authorization": "Bearer " + key])
        return try parse(response.data, apiKey: key)
    }
    static func parse(_ data: Data, apiKey: String, now: Date = Date()) throws -> NativeUsage {
        let usage = try NativeHTTP.decode(Envelope.self, from: data).data
        guard usage.currency == "USD", usage.totalCostUsd.isFinite, usage.totalCostUsd >= 0,
              let start = QuotaRules.date(usage.interval.startTime), let end = QuotaRules.date(usage.interval.endTime),
              start <= now, end > now else { throw ProviderFailure.parseChanged }
        return NativeUsage(cost: .init(used: usage.totalCostUsd, limit: 0, balance: nil,
            currency: "USD", period: "Gross usage before credits", resetsAt: end, reportsSpend: true,
            startsAt: start, periodID: "replit-" + String(Int(start.timeIntervalSince1970))),
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "replit", material: apiKey), updatedAt: now)
    }
}
