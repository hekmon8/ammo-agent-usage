import Foundation

/// OpenRouter balance and API-key spending cap. `/credits` is authoritative
/// for the money windows; `/key` is optional enrichment and its failure never
/// fails the fetch. The 30-day activity feed requires a separate management
/// key, which this client does not collect.
enum OpenRouterUsageReader {
    private static let base = URL(string: "https://openrouter.ai/api/v1")!

    private struct CreditsEnvelope: Decodable {
        struct Data: Decodable {
            let totalCredits: Double?
            let totalUsage: Double?
            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
        let data: Data?
    }

    private struct KeyEnvelope: Decodable {
        struct Data: Decodable {
            struct RateLimit: Decodable {
                let requests: Int?
                let interval: String?
            }
            let limit: Double?
            let limitRemaining: Double?
            let usage: Double?
            let usageDaily: Double?
            let usageWeekly: Double?
            let usageMonthly: Double?
            let limitReset: String?
            enum CodingKeys: String, CodingKey {
                case limit
                case limitRemaining = "limit_remaining"
                case usage
                case usageDaily = "usage_daily"
                case usageWeekly = "usage_weekly"
                case usageMonthly = "usage_monthly"
                case limitReset = "limit_reset"
            }
        }
        let data: Data?
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        let apiKey = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.kind == .apiKey, apiKey.hasPrefix("sk-or-") else {
            throw NativeProviderAPIError.credentialRejected
        }
        let headers = ["Authorization": "Bearer " + apiKey, "X-Title": "Ammo"]
        let creditsData: Data
        do {
            let response = try await NativeHTTP.request("GET", base.appendingPathComponent("credits"), headers: headers)
            creditsData = response.data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        // Optional: an explicit key-level spending cap becomes the percent window.
        var keyData: Data?
        if let keyResponse = try? await NativeHTTP.request("GET", base.appendingPathComponent("key"), headers: headers) {
            keyData = keyResponse.data
        }
        return try parse(creditsData: creditsData, keyData: keyData, apiKey: apiKey)
    }

    static func parse(creditsData: Data, keyData: Data?, apiKey: String) throws -> NativeUsage {
        let credits = try NativeHTTP.decode(CreditsEnvelope.self, from: creditsData)
        guard let creditsData_model = credits.data,
              let totalCredits = creditsData_model.totalCredits, totalCredits.isFinite,
              let totalUsage = creditsData_model.totalUsage, totalUsage.isFinite else {
            throw NativeProviderAPIError.parseFailure
        }
        var usage = NativeUsage(
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "openrouter", material: apiKey),
            updatedAt: Date())
        let balance = max(0, totalCredits - totalUsage)
        // Total credits are a running ledger, not a stoppable budget, so the
        // balance is exposed as money without a spend or budget window.
        usage.cost = .init(used: 0, limit: 0, balance: balance,
                           currency: "USD", period: "Credits")

        if let keyData,
           let key = try? NativeHTTP.decode(KeyEnvelope.self, from: keyData), let keyData_model = key.data,
           let limit = keyData_model.limit, limit > 0 {
            let used: Double?
            if let remaining = keyData_model.limitRemaining {
                used = limit - min(limit, max(0, remaining))
            } else {
                switch keyData_model.limitReset {
                case "daily": used = keyData_model.usageDaily
                case "weekly": used = keyData_model.usageWeekly
                case "monthly": used = keyData_model.usageMonthly
                default: used = keyData_model.usage
                }
            }
            if let used, used.isFinite, used >= 0 {
                usage.primary = .init(id: "key-limit",
                                      usedPercent: NativeAPIParsing.clampPercent(used / limit * 100))
            }
        }
        return usage
    }
}
