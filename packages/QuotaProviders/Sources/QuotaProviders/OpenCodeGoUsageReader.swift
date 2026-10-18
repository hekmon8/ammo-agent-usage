import Foundation

/// OpenCode Zen usage. The API-key channel reads the official usage endpoint
/// (rolling/weekly/monthly windows). The web-cookie channel reads only the
/// Zen prepaid balance through the workspace billing server; subscription
/// windows always come from the API endpoint.
enum OpenCodeGoUsageReader {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"

    private struct UsageEnvelope: Decodable {
        struct Window: Decodable {
            // Percent fields, tried in the documented order.
            let usagePercent: Double?
            let usedPercent: Double?
            let percentUsed: Double?
            let percent: Double?
            let usagePercentSnake: Double?
            let usedPercentSnake: Double?
            let utilization: Double?
            let utilizationPercent: Double?
            let utilizationPercentSnake: Double?
            // Fallback counters.
            let used: Double?
            let usage: Double?
            let consumed: Double?
            let limit: Double?
            let total: Double?
            let quota: Double?
            let cap: Double?
            // Reset fields.
            let resetInSec: Double?
            let resetInSeconds: Double?
            let resetSeconds: Double?
            let resetAt: NativeFlexibleDate?
            let resetsAt: NativeFlexibleDate?

            enum Keys: String, CodingKey {
                case usagePercent = "usagePercent"
                case usedPercent = "usedPercent"
                case percentUsed = "percentUsed"
                case percent
                case usagePercentSnake = "usage_percent"
                case usedPercentSnake = "used_percent"
                case utilization
                case utilizationPercent = "utilizationPercent"
                case utilizationPercentSnake = "utilization_percent"
                case used, usage, consumed, limit, total, quota, cap
                case resetInSec = "resetInSec"
                case resetInSeconds = "resetInSeconds"
                case resetSeconds = "resetSeconds"
                case resetAt, resetsAt
            }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                func optional(_ key: Keys) throws -> Double? {
                    if let number = try? values.decodeIfPresent(Double.self, forKey: key) { return number }
                    if let text = try? values.decodeIfPresent(String.self, forKey: key) { return Double(text) }
                    return nil
                }
                usagePercent = try optional(.usagePercent)
                usedPercent = try optional(.usedPercent)
                percentUsed = try optional(.percentUsed)
                percent = try optional(.percent)
                usagePercentSnake = try optional(.usagePercentSnake)
                usedPercentSnake = try optional(.usedPercentSnake)
                utilization = try optional(.utilization)
                utilizationPercent = try optional(.utilizationPercent)
                utilizationPercentSnake = try optional(.utilizationPercentSnake)
                used = try optional(.used)
                usage = try optional(.usage)
                consumed = try optional(.consumed)
                limit = try optional(.limit)
                total = try optional(.total)
                quota = try optional(.quota)
                cap = try optional(.cap)
                resetInSec = try optional(.resetInSec)
                resetInSeconds = try optional(.resetInSeconds)
                resetSeconds = try optional(.resetSeconds)
                resetAt = try? values.decodeIfPresent(NativeFlexibleDate.self, forKey: .resetAt)
                resetsAt = try? values.decodeIfPresent(NativeFlexibleDate.self, forKey: .resetsAt)
            }

            var percentValue: Double? {
                [usagePercent, usedPercent, percentUsed, percent, usagePercentSnake,
                 usedPercentSnake, utilization, utilizationPercent, utilizationPercentSnake]
                    .compactMap { $0 }.first
            }

            var usedValue: Double? { [used, usage, consumed].compactMap { $0 }.first }
            var limitValue: Double? { [limit, total, quota, cap].compactMap { $0 }.first }
            var resetSecondsValue: Double? {
                [resetInSec, resetInSeconds, resetSeconds].compactMap { $0 }.first
            }
            var resetDateValue: Date? { resetAt?.value ?? resetsAt?.value }
        }

        struct Usage: Decodable {
            let rolling: Window?
            let weekly: Window?
            let monthly: Window?
            let renewAt: NativeFlexibleDate?
        }

        let usage: Usage?
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        switch credential.kind {
        case .apiKey:
            let apiKey = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let data: Data
            do {
                data = try await NativeHTTP.request("GET", usageURL, headers: [
                    "Authorization": "Bearer " + apiKey,
                    "User-Agent": "Ammo/1",
                ]).data
            } catch let failure as NativeHTTP.Failure {
                if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
                if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
                throw failure
            }
            return try parse(usageData: data, balanceData: nil, seedMaterial: apiKey)
        case .cookie:
            return try await fetchZenBalance(credential: credential)
        default:
            throw NativeProviderAPIError.credentialRejected
        }
    }

    /// Usage windows from the API key endpoint. Percentages are 0-100 already;
    /// a used/limit pair is the accepted fallback shape.
    static func parse(usageData: Data, balanceData: Data?, seedMaterial: String) throws -> NativeUsage {
        let envelope = try NativeHTTP.decode(UsageEnvelope.self, from: usageData)
        guard let usageModel = envelope.usage else { throw NativeAPIParsingFailure.missingUsage }
        var usage = NativeUsage(
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "opencodego", material: seedMaterial),
            updatedAt: Date())
        usage.primary = window(usageModel.rolling, id: "rolling", minutes: 300)
        usage.secondary = window(usageModel.weekly, id: "weekly", minutes: 10_080)
        usage.tertiary = window(usageModel.monthly, id: "monthly", minutes: 43_200)
        if let renew = usageModel.renewAt?.value {
            // A renewal date is not a measured usage window; the normalizer drops it.
            usage.extraWindows.append(.init(id: "renewal", usedPercent: 0, windowMinutes: nil, resetsAt: renew))
        }
        if let balanceData { applyBalance(balanceData, to: &usage) }
        guard usage.primary != nil || usage.secondary != nil || usage.tertiary != nil || usage.cost != nil else {
            throw NativeProviderAPIError.parseFailure
        }
        return usage
    }

    private enum NativeAPIParsingFailure: Error { case missingUsage }

    private static func window(_ raw: UsageEnvelope.Window?, id: String, minutes: Int?) -> NativeUsage.Window? {
        guard let raw else { return nil }
        let percent: Double?
        if let published = raw.percentValue {
            percent = NativeAPIParsing.clampPercent(published)
        } else if let used = raw.usedValue, let limit = raw.limitValue, limit > 0 {
            percent = NativeAPIParsing.clampPercent(used / limit * 100)
        } else {
            return nil
        }
        guard let percent else { return nil }
        let reset = raw.resetSecondsValue.map { Date().addingTimeInterval($0) } ?? raw.resetDateValue
        return .init(id: id, usedPercent: percent, windowMinutes: minutes, resetsAt: reset)
    }

    // MARK: - Zen balance via the cookie channel

    private struct BillingCandidate {
        let customerID: String
        let balance: Double
    }

    private static func applyBalance(_ data: Data, to usage: inout NativeUsage) {
        guard let candidate = Self.billingCandidate(in: data),
              candidate.balance.isFinite, candidate.balance >= 0 else { return }
        let balance = candidate.balance / 100_000_000
        usage.cost = .init(used: 0, limit: 0, balance: balance,
                           currency: "USD", period: "Zen balance")
    }

    static func applyZenBalanceForTesting(_ data: Data, to usage: inout NativeUsage) {
        applyBalance(data, to: &usage)
    }

    /// Finds the billing object carrying both a customerID and a balance in
    /// the server-function response.
    private static func billingCandidate(in data: Data) -> BillingCandidate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return Self.search(object)
    }

    private static func search(_ value: Any) -> BillingCandidate? {
        if let dict = value as? [String: Any] {
            if let customer = dict["customerID"] as? String, !customer.isEmpty,
               let balance = Self.number(dict["balance"]) {
                return BillingCandidate(customerID: customer, balance: balance)
            }
            for nested in dict.values {
                if let found = Self.search(nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = Self.search(nested) { return found }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let integer = value as? Int { return Double(integer) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// Only the session cookies the web app actually authenticates with.
    static func requestCookieHeader(from raw: String) -> String? {
        let allowed = ["auth", "__host-auth"]
        let pairs = raw.split(separator: ";").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard allowed.contains(name.lowercased()) else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : "\(name)=\(value)"
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    private static func fetchZenBalance(credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .cookie,
              let cookie = requestCookieHeader(from: credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        var workspaceID = credential.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if workspaceID.isEmpty {
            workspaceID = try await discoverWorkspaceID(cookie: cookie) ?? ""
        }
        guard workspaceID.hasPrefix("wrk_") else { throw NativeProviderAPIError.parseFailure }
        var components = URLComponents(url: URL(string: "https://opencode.ai/_server")!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: billingServerID),
            URLQueryItem(name: "args", value: "[\"\(workspaceID)\"]"),
        ]
        guard let url = components.url else { throw NativeProviderAPIError.parseFailure }
        let data: Data
        do {
            data = try await NativeHTTP.request("GET", url, headers: serverHeaders(cookie: cookie, referer: "https://opencode.ai/workspace/\(workspaceID)")).data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        var usage = NativeUsage(
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "opencodego", material: cookie),
            updatedAt: Date())
        applyBalance(data, to: &usage)
        guard usage.cost != nil else { throw NativeProviderAPIError.parseFailure }
        return usage
    }

    private static func serverHeaders(cookie: String, referer: String) -> [String: String] {
        [
            "Cookie": cookie,
            "X-Server-Id": billingServerID,
            "X-Server-Instance": "server-fn:" + UUID().uuidString,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            "Origin": "https://opencode.ai",
            "Referer": referer,
            "Accept": "text/javascript, application/json;q=0.9, */*;q=0.8",
        ]
    }

    private static func discoverWorkspaceID(cookie: String) async throws -> String? {
        let url = URL(string: "https://opencode.ai/_server?id=\(workspacesServerID)")!
        let data: Data
        do {
            data = try await NativeHTTP.request("GET", url,
                headers: serverHeaders(cookie: cookie, referer: "https://opencode.ai")).data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        return Self.firstWorkspaceID(in: data)
    }

    static func firstWorkspaceID(in data: Data) -> String? {
        func search(_ value: Any) -> String? {
            if let text = value as? String {
                return text.hasPrefix("wrk_") ? text : nil
            }
            if let dict = value as? [String: Any] {
                for (key, nested) in dict {
                    if key == "id", let text = nested as? String, text.hasPrefix("wrk_") { return text }
                    if let found = search(nested) { return found }
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    if let found = search(nested) { return found }
                }
            }
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            if let text = String(data: data, encoding: .utf8),
               let range = text.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
                return String(text[range])
            }
            return nil
        }
        return search(object)
    }
}
