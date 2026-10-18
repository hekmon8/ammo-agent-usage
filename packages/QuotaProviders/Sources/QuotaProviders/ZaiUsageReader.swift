import Foundation

/// z.ai / GLM quota via the official monitor endpoints. The region selects
/// the platform (open.bigmodel.cn vs api.z.ai); a team scope adds the
/// organization/project headers and the team query flag. The China console
/// balance is a best-effort enrichment that never fails the fetch.
enum ZaiUsageReader {
    private struct QuotaEnvelope: Decodable {
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let usage: Double?
            let currentValue: Double?
            let remaining: Double?
            let nextResetTime: Double?
        }
        struct Data: Decodable {
            let planName: String?
            let plan: String?
            let planType: String?
            let packageName: String?
            let level: String?
            let limits: [Limit]?
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                planName = try values.decodeIfPresent(String.self, forKey: .planName)
                plan = try values.decodeIfPresent(String.self, forKey: .plan)
                planType = try values.decodeIfPresent(String.self, forKey: .planType)
                packageName = try values.decodeIfPresent(String.self, forKey: .packageName)
                level = try values.decodeIfPresent(String.self, forKey: .level)
                limits = try values.decodeIfPresent([Limit].self, forKey: .limits)
            }
            enum Keys: String, CodingKey {
                case planName, plan
                case planType = "plan_type"
                case packageName
                case level
                case limits
            }
        }
        let success: Bool?
        let code: Int?
        let msg: String?
        let data: Data?
    }

    private struct BalanceEnvelope: Decodable {
        struct Data: Decodable {
            let availableBalance: Double?
            let balance: Double?
        }
        let success: Bool?
        let data: Data?
    }

    private static let unitMinutes: [Int: Int] = [1: 1440, 3: 60, 5: 1, 6: 10_080]

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        let apiKey = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.kind == .apiKey, !apiKey.isEmpty else { throw NativeProviderAPIError.credentialRejected }
        let region = credential.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "global"
        guard region == "bigmodel-cn" || region == "global" else { throw NativeProviderAPIError.credentialRejected }
        let base = region == "global" ? "https://api.z.ai" : "https://open.bigmodel.cn"
        let (teamScope, headers) = try requestHeaders(for: credential, apiKey: apiKey)
        let quotaURL = URL(string: base + "/api/monitor/usage/quota/limit" + (teamScope ? "?type=2" : ""))!
        let quotaData: Data
        do {
            let response = try await NativeHTTP.request("GET", quotaURL, headers: headers)
            quotaData = response.data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.permissionDenied }
            throw failure
        }
        // The China console balance is a best-effort enrichment that never fails the fetch.
        var balanceData: Data?
        if region == "bigmodel-cn" {
            let balanceURL = URL(string: "https://www.bigmodel.cn/api/biz/account/query-customer-account-report")!
            if let balanceResponse = try? await NativeHTTP.request("GET", balanceURL, headers: headers, timeout: 5) {
                balanceData = balanceResponse.data
            }
        }
        return try parse(quotaData: quotaData, balanceData: balanceData,
                         seed: Self.seed(apiKey: apiKey, region: region, credential: credential))
    }

    /// A team request requires both scope identifiers; reject damaged or
    /// partially migrated credentials before constructing any HTTP request.
    static func requestHeaders(for credential: NativeProviderCredential, apiKey: String) throws -> (Bool, [String: String]) {
        let organization = credential.organizationID
        let project = credential.workspaceID
        var headers = ["Authorization": "Bearer " + apiKey]
        switch (organization, project) {
        case (nil, nil):
            return (false, headers)
        case let (.some(organization), .some(project))
            where !organization.isEmpty && !project.isEmpty:
            headers["Bigmodel-Organization"] = organization
            headers["Bigmodel-Project"] = project
            return (true, headers)
        default:
            throw NativeProviderAPIError.credentialRejected
        }
    }

    /// The released bridge digested the API key together with the scoped
    /// region/scope (and team org/project) fields; reproduce it exactly.
    static func seed(apiKey: String, region: String, credential: NativeProviderCredential) -> String {
        var values = [
            "Z_AI_API_KEY": apiKey,
            "scope:region": region,
            "scope:usageScope": (credential.organizationID ?? "").isEmpty ? "personal" : "team",
        ]
        if let organization = credential.organizationID, !organization.isEmpty {
            values["scope:organization"] = organization
        }
        if let project = credential.workspaceID, !project.isEmpty {
            values["scope:project"] = project
        }
        return NativeAPIParsing.legacyCredentialsSeed(provider: "zai", values: values)
    }

    static func parse(quotaData: Data, balanceData: Data?, seed: String) throws -> NativeUsage {
        let envelope = try NativeHTTP.decode(QuotaEnvelope.self, from: quotaData)
        guard envelope.success == true, envelope.code == 200 else {
            if envelope.code == 401 { throw NativeProviderAPIError.credentialRejected }
            throw NativeProviderAPIError.parseFailure
        }
        guard let limits = envelope.data?.limits, !limits.isEmpty else { throw NativeProviderAPIError.parseFailure }
        var usage = NativeUsage(
            identitySeed: seed,
            updatedAt: Date())

        var windows: [(minutes: Int, used: Double, resetsAt: Date?)] = []
        for limit in limits {
            let reset = limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000) }
            if limit.type == "TIME_LIMIT" {
                let monthlyMCP = limit.unit == 5 && limit.number == 1
                let minutes = monthlyMCP ? 43_200 : windowMinutes(limit)
                usage.extraWindows.append(.init(id: "zai-mcp", usedPercent: usedPercent(limit),
                                                windowMinutes: minutes, resetsAt: reset))
                continue
            }
            guard limit.type == "TOKENS_LIMIT" || limit.type == "CREDIT_LIMIT" else { continue }
            windows.append((windowMinutes(limit), usedPercent(limit), reset))
        }
        // Short window first: the session bucket leads, the weekly bucket follows.
        for (index, window) in windows.sorted(by: { $0.minutes < $1.minutes }).enumerated() {
            let windowValue = NativeUsage.Window(id: "zai-\(window.minutes)m", usedPercent: window.used,
                                                 windowMinutes: window.minutes, resetsAt: window.resetsAt)
            switch index {
            case 0: usage.primary = windowValue
            case 1: usage.secondary = windowValue
            default: usage.extraWindows.append(windowValue)
            }
        }

        if let balanceData,
           let balance = try? NativeHTTP.decode(BalanceEnvelope.self, from: balanceData),
           balance.success == true, let available = balance.data?.availableBalance ?? balance.data?.balance,
           available.isFinite, available >= 0 {
            usage.cost = .init(used: available, limit: 0, balance: available,
                               currency: "CNY", period: "Balance")
        }
        guard usage.primary != nil || usage.secondary != nil || !usage.extraWindows.isEmpty else {
            throw NativeProviderAPIError.parseFailure
        }
        return usage
    }

    private static func windowMinutes(_ limit: QuotaEnvelope.Limit) -> Int {
        if let unit = limit.unit, let number = limit.number, let multiplier = unitMinutes[unit] {
            return number * multiplier
        }
        return 0
    }

    /// The API publishes the used percentage directly; when a token budget is
    /// present it cross-checks and refines the ratio.
    private static func usedPercent(_ limit: QuotaEnvelope.Limit) -> Double {
        if let usage = limit.usage, usage > 0 {
            let used: Double
            if let remaining = limit.remaining {
                used = max(usage - remaining, limit.currentValue ?? 0)
            } else {
                used = limit.currentValue ?? 0
            }
            return NativeAPIParsing.clampPercent(min(usage, used) / usage * 100)
        }
        return NativeAPIParsing.clampPercent(limit.percentage ?? 0)
    }
}
