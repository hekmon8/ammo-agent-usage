import Foundation

/// Factory (Droid) quota via the app's own web API with an API key bearer
/// token. The token-rate-limits billing endpoint supplies the windows; the
/// legacy subscription-usage endpoint is the fallback shape.
enum FactoryUsageReader {
    private static let bases = ["https://api.factory.ai", "https://app.factory.ai"]
    private static let headers: [String: String] = [
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Origin": "https://app.factory.ai",
        "Referer": "https://app.factory.ai/",
        "x-factory-client": "web-app",
    ]

    private struct AuthEnvelope: Decodable {
        struct UserProfile: Decodable {
            struct WorkosUser: Decodable {
                let id: String?
            }
            let id: String?
            let email: String?
            let workosUser: WorkosUser?
            /// Newer profiles dropped the top-level id; the WorkOS id stands in.
            var resolvedID: String? { id ?? workosUser?.id }
        }
        struct Organization: Decodable {
            let id: String?
            let name: String?
        }
        let userProfile: UserProfile?
        let organization: Organization?
    }

    private struct LimitsEnvelope: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let secondsRemaining: Double?
            let windowEnd: NativeFlexibleDate?
        }
        struct Group: Decodable {
            let fiveHour: Window?
            let weekly: Window?
            let monthly: Window?
        }
        struct Data: Decodable {
            let usesTokenRateLimitsBilling: Bool?
            let standard: Group?
            let core: Group?
            let extraUsageBalanceCents: Int?
        }
        private struct LimitsGroup: Decodable {
            let standard: Group?
            let core: Group?
        }
        private enum CodingKeys: String, CodingKey {
            case data, limits
            case usesTokenRateLimitsBilling
            case extraUsageBalanceCents
        }

        let data: Data?

        // The endpoint moved the flag and balance to the top level with the
        // groups nested under `limits`; the older shape wrapped everything
        // in `data`. Accept both.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let wrapped = try container.decodeIfPresent(Data.self, forKey: .data) {
                data = wrapped
                return
            }
            let groups = try container.decodeIfPresent(LimitsGroup.self, forKey: .limits)
            data = Data(
                usesTokenRateLimitsBilling: try container.decodeIfPresent(
                    Bool.self, forKey: .usesTokenRateLimitsBilling),
                standard: groups?.standard,
                core: groups?.core,
                extraUsageBalanceCents: try container.decodeIfPresent(
                    Int.self, forKey: .extraUsageBalanceCents))
        }
    }

    /// Org compute-hours for managed computers: `orgUsageMs`/`limitMs` are
    /// milliseconds, `periodEnd` closes the billing-cycle window. The web
    /// dashboard hides the section when `limitMs` is null.
    private struct ComputeUsageEnvelope: Decodable {
        let orgUsageMs: Double?
        let limitMs: Double?
        let periodEnd: NativeFlexibleDate?
        let overageAllowed: Bool?
    }

    private struct UsageEnvelope: Decodable {
        struct Usage: Decodable {
            let startDate: Double?
            let endDate: Double?
            let userTokens: Double?
            let orgTotalTokensUsed: Double?
            let totalAllowance: Double?
            let usedRatio: Double?
        }
        struct Data: Decodable {
            let usage: Usage?
            let userID: String?
            enum CodingKeys: String, CodingKey {
                case usage
                case userID = "userId"
            }
        }
        let data: Data?
    }

    /// Epoch seconds, epoch milliseconds, numeric strings, or ISO8601.
    typealias FlexibleDate = NativeFlexibleDate

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey else { throw NativeProviderAPIError.credentialRejected }
        var token = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let segments = token.split(separator: ".").count
        guard token.count >= 20 || segments == 3 else { throw NativeProviderAPIError.credentialRejected }
        var requestHeaders = headers
        requestHeaders["Authorization"] = "Bearer " + token

        var authData: Data?
        var lastError: Error = NativeProviderAPIError.parseFailure
        for base in bases {
            do {
                authData = try await NativeHTTP.request(
                    "GET", URL(string: base + "/api/app/auth/me")!, headers: requestHeaders).data
                break
            } catch let failure as NativeHTTP.Failure {
                if case .httpStatus(401) = failure {
                    throw NativeProviderAPIError.credentialRejected
                }
                lastError = failure
            } catch {
                lastError = error
            }
        }
        guard authData != nil else { throw lastError }
        var limitsData: Data?
        for base in bases {
            if let data = try? await NativeHTTP.request(
                "GET", URL(string: base + "/api/billing/limits")!, headers: requestHeaders).data {
                limitsData = data
                break
            }
        }
        // The legacy usage endpoint only matters when the billing limits
        // response did not carry the new token-rate-limits shape.
        var usageData: Data?
        if !hasWindows(limitsData: limitsData) {
            let userID = (try? NativeHTTP.decode(AuthEnvelope.self, from: authData!))?.userProfile?.resolvedID
            if let userID {
                let url = URL(string: "https://api.factory.ai/api/organization/subscription/usage?useCache=true&userId=\(userID)")!
                usageData = try? await NativeHTTP.request("GET", url, headers: requestHeaders).data
            }
        }
        // Org compute hours live on their own endpoint; plans without the
        // feature get 403/404 here, which the tolerant fetch turns into nil.
        var computeData: Data?
        for base in bases {
            if let data = try? await NativeHTTP.request(
                "GET", URL(string: base + "/api/organization/compute-usage")!, headers: requestHeaders).data {
                computeData = data
                break
            }
        }
        return try parse(authData: authData!, limitsData: limitsData, usageData: usageData,
                         computeData: computeData, credential: credential)
    }

    static func hasWindows(limitsData: Data?) -> Bool {
        guard let limitsData,
              let limits = try? NativeHTTP.decode(LimitsEnvelope.self, from: limitsData),
              let model = limits.data else { return false }
        return model.usesTokenRateLimitsBilling == true && model.standard != nil
    }

    static func parse(authData: Data, limitsData: Data?, usageData: Data?, computeData: Data? = nil,
                      credential: NativeProviderCredential) throws -> NativeUsage {
        var usage = NativeUsage(updatedAt: Date())
        if let auth = try? NativeHTTP.decode(AuthEnvelope.self, from: authData) {
            usage.identity = .init(
                accountID: auth.userProfile?.resolvedID,
                email: auth.userProfile?.email,
                organization: auth.organization?.id ?? auth.organization?.name)
        }

        if let limitsData,
           let limits = try? NativeHTTP.decode(LimitsEnvelope.self, from: limitsData),
           let model = limits.data, model.usesTokenRateLimitsBilling == true {
            if let standard = model.standard {
                usage.primary = window(standard.fiveHour, minutes: 300)
                usage.secondary = window(standard.weekly, minutes: 10_080)
                usage.tertiary = window(standard.monthly, minutes: nil)
            }
            if let core = model.core {
                for (id, raw, minutes) in [("core-5h", core.fiveHour, 300), ("core-7d", core.weekly, 10_080),
                                           ("core-monthly", core.monthly, nil)] {
                    if let extra = window(raw, minutes: minutes) {
                        usage.extraWindows.append(.init(id: id, usedPercent: extra.usedPercent,
                                                        windowMinutes: extra.windowMinutes, resetsAt: extra.resetsAt))
                    }
                }
            }
            if let cents = model.extraUsageBalanceCents, cents > 0 {
                usage.cost = .init(used: Double(cents) / 100, limit: 0, balance: Double(cents) / 100,
                                   currency: "USD", period: "Extra usage balance")
            }
        }

        // Managed Computers: only a real limit yields a window; the dashboard
        // likewise hides the section when the limit is null.
        if let computeData,
           let compute = try? NativeHTTP.decode(ComputeUsageEnvelope.self, from: computeData),
           let limitMs = compute.limitMs, limitMs > 0 {
            let usedMs = compute.orgUsageMs ?? 0
            let usedPercent = max(0, min(100, usedMs / limitMs * 100))
            usage.extraWindows.append(.init(id: "compute", usedPercent: usedPercent,
                                            windowMinutes: nil, resetsAt: compute.periodEnd?.value))
        }

        if usage.primary == nil, usage.secondary == nil, usage.tertiary == nil,
           let usageData,
           let legacy = try? NativeHTTP.decode(UsageEnvelope.self, from: usageData),
           let legacyUsage = legacy.data?.usage {
            let percent: Double?
            if let ratio = legacyUsage.usedRatio {
                percent = NativeAPIParsing.clampPercent(ratio <= 1 ? ratio * 100 : ratio)
            } else if let allowance = legacyUsage.totalAllowance, allowance > 0,
                      let used = legacyUsage.orgTotalTokensUsed ?? legacyUsage.userTokens {
                percent = NativeAPIParsing.clampPercent(used / allowance * 100)
            } else {
                percent = nil
            }
            if let percent {
                let start = legacyUsage.startDate.map { Date(timeIntervalSince1970: $0 / 1000) }
                let end = legacyUsage.endDate.map { Date(timeIntervalSince1970: $0 / 1000) }
                let minutes: Int? = start.flatMap { startValue in
                    end.map { max(1, Int($0.timeIntervalSince(startValue) / 60)) }
                }
                usage.primary = .init(id: "allowance", usedPercent: percent,
                                      windowMinutes: minutes, resetsAt: end)
            }
        }
        guard usage.primary != nil || usage.secondary != nil || usage.tertiary != nil
                || usage.cost != nil || !usage.extraWindows.isEmpty else {
            throw NativeProviderAPIError.parseFailure
        }
        if usage.identity.accountID == nil, usage.identity.email == nil {
            usage.identitySeed = NativeAPIParsing.legacyCredentialSeed(
                provider: "factory", material: credential.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return usage
    }

    private static func window(_ raw: LimitsEnvelope.Window?, minutes: Int?) -> NativeUsage.Window? {
        guard let raw else { return nil }
        let reset = raw.secondsRemaining.map { Date().addingTimeInterval($0) }
            ?? raw.windowEnd?.value
        guard let percent = raw.usedPercent ?? (reset == nil ? nil : 0) else { return nil }
        return .init(id: "factory", usedPercent: NativeAPIParsing.clampPercent(percent),
                     windowMinutes: minutes, resetsAt: reset)
    }
}
