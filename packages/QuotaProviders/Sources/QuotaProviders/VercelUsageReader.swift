import Foundation
import QuotaCore

/// FOCUS daily export, calendar-month usage charges only. Excludes purchase,
/// tax and credit rows; this is not the final invoice or a realtime meter.
enum VercelUsageReader {
    struct Charge: Decodable {
        let BilledCost: Decimal
        let BillingCurrency: String
        let ChargeCategory: String
        let ChargePeriodStart: String
        let ChargePeriodEnd: String
        enum CodingKeys: String, CodingKey { case BilledCost, BillingCurrency, ChargeCategory, ChargePeriodStart, ChargePeriodEnd }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? c.decode(String.self, forKey: .BilledCost),
               text.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil,
               let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN {
                BilledCost = number
            } else { BilledCost = try c.decode(Decimal.self, forKey: .BilledCost) }
            BillingCurrency = try c.decode(String.self, forKey: .BillingCurrency)
            ChargeCategory = try c.decode(String.self, forKey: .ChargeCategory)
            ChargePeriodStart = try c.decode(String.self, forKey: .ChargePeriodStart)
            ChargePeriodEnd = try c.decode(String.self, forKey: .ChargePeriodEnd)
        }
    }
    static func month(containing now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: now)!
    }
    static func requestURL(teamID: String, now: Date) throws -> URL {
        guard teamID.range(of: "^team_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw ProviderFailure.parseChanged }
        let period = month(containing: now)
        let format = ISO8601DateFormatter()
        var url = URLComponents(string: "https://api.vercel.com/v1/billing/charges")!
        url.queryItems = [URLQueryItem(name: "teamId", value: teamID),
            URLQueryItem(name: "from", value: format.string(from: period.start)),
            URLQueryItem(name: "to", value: format.string(from: now))]
        return url.url!
    }
    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey, let teamID = credential.organizationID else { throw ProviderFailure.authRequired }
        let now = Date()
        let response = try await NativeHTTP.request("GET", requestURL(teamID: teamID, now: now),
            headers: ["Authorization": "Bearer " + credential.value.trimmingCharacters(in: .whitespacesAndNewlines)])
        return try parse(response.data, teamID: teamID, now: now)
    }
    static func parse(_ data: Data, teamID: String, now: Date) throws -> NativeUsage {
        _ = try requestURL(teamID: teamID, now: now)
        guard data.count <= NativeHTTP.maxResponseBytes, let body = String(data: data, encoding: .utf8) else { throw ProviderFailure.parseChanged }
        let period = month(containing: now)
        var sum = Decimal.zero
        var currency: String?
        for line in body.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let row = try NativeHTTP.decode(Charge.self, from: Data(line.utf8))
            guard let start = QuotaRules.date(row.ChargePeriodStart), let end = QuotaRules.date(row.ChargePeriodEnd),
                  start >= period.start, start < now, end > start,
                  row.BillingCurrency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  !row.BilledCost.isNaN else { throw ProviderFailure.parseChanged }
            guard row.ChargeCategory == "Usage" else { continue }
            guard currency == nil || currency == row.BillingCurrency else { throw ProviderFailure.parseChanged }
            currency = row.BillingCurrency
            sum += row.BilledCost
        }
        // An empty export cannot prove a zero bill (data may not have arrived).
        guard let currency, sum >= 0 else { throw ProviderFailure.unsupported }
        let used = NSDecimalNumber(decimal: sum).doubleValue
        guard used.isFinite else { throw ProviderFailure.parseChanged }
        return NativeUsage(cost: .init(used: used, limit: 0, balance: nil, currency: currency,
            period: "Calendar month usage", resetsAt: period.end, reportsSpend: true, startsAt: period.start,
            periodID: "vercel-" + String(Int(period.start.timeIntervalSince1970))),
            identity: .init(accountID: teamID), updatedAt: now)
    }
}
