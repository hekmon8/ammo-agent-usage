import Foundation

/// Manus credits via the Connect-RPC endpoint, authenticated with the web
/// session's `session_id` cookie value sent as a bearer token. The response's
/// monthly and per-refresh credit buckets become the two windows.
enum ManusUsageReader {
    private static let endpoint = URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!

    /// Every numeric field may arrive as number or string; decode both.
    private struct CreditsEnvelope: Decodable {
        let totalCredits: Double?
        let freeCredits: Double?
        let periodicCredits: Double?
        let refreshCredits: Double?
        let maxRefreshCredits: Double?
        let proMonthlyCredits: Double?
        let nextRefreshTime: String?

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            totalCredits = try Self.lossy(values, .totalCredits)
            freeCredits = try Self.lossy(values, .freeCredits)
            periodicCredits = try Self.lossy(values, .periodicCredits)
            refreshCredits = try Self.lossy(values, .refreshCredits)
            maxRefreshCredits = try Self.lossy(values, .maxRefreshCredits)
            proMonthlyCredits = try Self.lossy(values, .proMonthlyCredits)
            nextRefreshTime = try values.decodeIfPresent(String.self, forKey: .nextRefreshTime)
        }

        static func lossy(_ values: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> Double? {
            if let number = try? values.decodeIfPresent(Double.self, forKey: key) { return number }
            if let text = try? values.decodeIfPresent(String.self, forKey: key) { return Double(text) }
            return nil
        }

        enum Keys: String, CodingKey {
            case totalCredits, freeCredits, periodicCredits, refreshCredits
            case maxRefreshCredits, proMonthlyCredits, nextRefreshTime
        }
    }

    /// A pasted cookie header is reduced to its `session_id` pair.
    static func sessionID(from raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cookie:") { trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if trimmed.contains("; ") || trimmed.lowercased().contains("session_id=") {
            for pair in trimmed.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "session_id" {
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
            return nil
        }
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        return trimmed
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .cookie, let session = sessionID(from: credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        let data: Data
        do {
            data = try await NativeHTTP.request("POST", endpoint, headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": "Bearer " + session,
                "Origin": "https://manus.im",
                "Referer": "https://manus.im/",
                "Connect-Protocol-Version": "1",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            ], body: Data("{}".utf8)).data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        return try parse(data: data, session: session)
    }

    static func parse(data: Data, session: String) throws -> NativeUsage {
        // Unwrap the Connect envelope, then require at least one known credit
        // field so an error payload can never render as a fake zero balance.
        var object = (try? JSONSerialization.jsonObject(with: data)).flatMap { $0 as? [String: Any] } ?? [:]
        for wrapper in ["data", "result", "response", "availableCredits"] {
            if let nested = object[wrapper] as? [String: Any] {
                object = nested
                break
            }
        }
        let knownKeys = ["totalCredits", "freeCredits", "periodicCredits", "refreshCredits",
                         "maxRefreshCredits", "proMonthlyCredits", "eventCredits", "addonCredits"]
        guard knownKeys.contains(where: { object[$0] != nil }) else { throw NativeProviderAPIError.parseFailure }
        let payload = try JSONSerialization.data(withJSONObject: object)
        let credits = try NativeHTTP.decode(CreditsEnvelope.self, from: payload)
        var usage = NativeUsage(
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "manus", material: session),
            updatedAt: Date())
        if let monthly = credits.proMonthlyCredits, monthly > 0 {
            let periodic = credits.periodicCredits ?? 0
            usage.primary = .init(id: "monthly",
                usedPercent: NativeAPIParsing.clampPercent((monthly - periodic) / monthly * 100))
        }
        if let maxRefresh = credits.maxRefreshCredits, maxRefresh > 0 {
            let remaining = credits.refreshCredits ?? 0
            usage.secondary = .init(id: "refresh",
                usedPercent: NativeAPIParsing.clampPercent((maxRefresh - remaining) / maxRefresh * 100),
                windowMinutes: nil, resetsAt: NativeAPIParsing.date(credits.nextRefreshTime))
        }
        guard usage.primary != nil || usage.secondary != nil else {
            throw NativeProviderAPIError.parseFailure
        }
        return usage
    }
}
