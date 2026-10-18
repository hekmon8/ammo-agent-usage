import CryptoKit
import Darwin
import Foundation
import QuotaCore

/// Read-only access to the machine's existing Codex login (`~/.codex/auth.json`).
/// It never refreshes tokens, never modifies the owning CLI's login, and always
/// talks to the official endpoints. The identity digest is part of the released
/// connection format and must not change.
public struct CodexLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "codex", displayName: "Codex", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    public static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    public struct Credentials {
        let accessToken: String
        let idToken: String?
        let accountID: String?

        /// Expired tokens are the CLI's to refresh; a stale read never invents usage.
        var needsRefresh: Bool {
            if let expiresAt = Self.expirationFromJWT(accessToken: accessToken) {
                return expiresAt.timeIntervalSinceNow <= 5 * 60
            }
            return false
        }

        var identityFingerprint: String? {
            for token in [accessToken, idToken].compactMap({ $0 }) where !token.isEmpty {
                guard let claims = Self.jwtClaims(token), let subject = claims["sub"] as? String,
                      !subject.isEmpty, subject.utf8.count <= 256,
                      subject.rangeOfCharacter(from: .controlCharacters) == nil,
                      let accountID else { continue }
                return NativeProviderNormalizer.sha256("codex-local-login\n\(accountID)\n\(subject)")
            }
            return nil
        }

        static func jwtClaims(_ token: String) -> [String: Any]? {
            let parts = token.split(separator: ".")
            guard parts.count == 3, parts[1].utf8.count <= 32_768 else { return nil }
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        static func expirationFromJWT(accessToken: String) -> Date? {
            guard let claims = jwtClaims(accessToken), let raw = claims["exp"] as? Double else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
    }

    /// Mirrors the CLI's credential file: token entry first, explicit API-key
    /// files are rejected (they cannot call the usage endpoint).
    public static func readCredentials(from data: Data, now: Date = Date()) throws -> Credentials {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // The CLI may persist the key slot as JSON null alongside tokens;
              // only a real key string means the file is not an OAuth login.
              (json["OPENAI_API_KEY"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } != true,
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = Self.string(tokens["access_token"]) ?? Self.string(tokens["accessToken"]),
              let refreshToken = Self.string(tokens["refresh_token"]) ?? Self.string(tokens["refreshToken"]),
              !accessToken.isEmpty, !refreshToken.isEmpty
        else { throw ProviderFailure.authRequired }
        guard accessToken.utf8.count <= 32_768,
              accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              accessToken.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProviderFailure.authRequired
        }
        let idToken = Self.string(tokens["id_token"]) ?? Self.string(tokens["idToken"])
        let accountID = Self.string(tokens["account_id"]) ?? Self.string(tokens["accountId"])
            ?? Self.accountIDFromJWT(accessToken: accessToken, idToken: idToken)
        if let expiresAt = Credentials.expirationFromJWT(accessToken: accessToken),
           expiresAt.addingTimeInterval(-300) <= now {
            throw ProviderFailure.authRequired
        }
        guard let accountID, !accountID.isEmpty, accountID.utf8.count <= 256,
              accountID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProviderFailure.authRequired
        }
        return Credentials(accessToken: accessToken, idToken: idToken, accountID: accountID)
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func accountIDFromJWT(accessToken: String, idToken: String?) -> String? {
        for token in [idToken, accessToken].compactMap({ $0 }) where !token.isEmpty {
            if let claims = Credentials.jwtClaims(token),
               let account = claims["chatgpt_account_id"] as? String, !account.isEmpty {
                return account
            }
        }
        return nil
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil, authFile: authFile)
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity, authFile: Self.authFile)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    static func read(alias: String, expectedIdentity: String?, authFile: URL) async throws -> NativeProviderProbeResult {
        try Task.checkCancellation()
        let credentials = try readCredentials(from: try readPrivateAuth(authFile))
        guard let fingerprint = credentials.identityFingerprint else { throw ProviderFailure.authRequired }
        guard expectedIdentity == nil || expectedIdentity == fingerprint else { throw ProviderFailure.authRequired }
        guard let remoteAccountID = credentials.accountID else { throw ProviderFailure.authRequired }
        let accountID = "account-" + String(fingerprint.prefix(16))
        let usageData = try await request(.usage, accessToken: credentials.accessToken, accountID: remoteAccountID)
        let resetsData: Data?
        do {
            resetsData = try await request(.rateLimitResetCredits, accessToken: credentials.accessToken,
                                           accountID: remoteAccountID)
        } catch {
            if error is CancellationError { throw CancellationError() }
            // Reset inventory is optional enrichment; its failure never discards
            // successfully fetched primary/Spark/credit data.
            resetsData = nil
        }
        let windows = try normalize(usageData: usageData, resetsData: resetsData,
                                    remoteAccountID: remoteAccountID,
                                    accountID: accountID, alias: alias, now: Date())
        return NativeProviderProbeResult(accountID: accountID, identityFingerprint: fingerprint, windows: windows)
    }

    private static func readPrivateAuth(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ENOENT ? ProviderFailure.authRequired : ProviderFailure.permissionDenied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw ProviderFailure.permissionDenied }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw ProviderFailure.outputLimit }
        return data
    }

    enum Endpoint {
        case usage
        case rateLimitResetCredits

        var path: String {
            switch self {
            case .usage: return "/backend-api/wham/usage"
            case .rateLimitResetCredits: return "/backend-api/wham/rate-limit-reset-credits"
            }
        }
    }

    static func request(_ endpoint: Endpoint, accessToken: String, accountID: String) async throws -> Data {
        var components = URLComponents(url: URL(string: "https://chatgpt.com")!, resolvingAgainstBaseURL: false)!
        components.path = endpoint.path
        guard let url = components.url else { throw ProviderFailure.parseChanged }
        do {
            let response = try await NativeHTTP.request("GET", url, headers: [
                "Authorization": "Bearer " + accessToken,
                "ChatGPT-Account-Id": accountID,
                "User-Agent": "Ammo/1",
            ])
            return response.data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw ProviderFailure.authRequired }
            if case .httpStatus(403) = failure { throw ProviderFailure.authRequired }
            if case .httpStatus(429) = failure { throw ProviderFailure.rateLimited(seconds: 300) }
            throw failure
        }
    }

    // MARK: - Response mapping

    /// Maps the usage response onto the shared Codex envelope so window
    /// semantics (primary/weekly/Spark/credits/reset inventory) stay identical
    /// to the isolated-profile channel.
    static func normalize(usageData: Data, resetsData: Data?, remoteAccountID: String,
                          accountID: String, alias: String, now: Date) throws -> [QuotaWindow] {
        guard let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            throw ProviderFailure.parseChanged
        }
        // The endpoint is scoped by the account header; a mismatched account in
        // the response means the login no longer belongs to this connection.
        if let responseAccount = Self.string(usage["account_id"]) ?? Self.string(usage["accountId"]),
           !responseAccount.isEmpty, responseAccount != remoteAccountID {
            throw ProviderFailure.authRequired
        }
        func windowDict(_ value: [String: Any]?) throws -> [String: Any]? {
            guard let value else { return nil }
            guard let seconds = value["limit_window_seconds"] as? Int,
                  seconds > 0, seconds % 60 == 0, let usedPercent = value["used_percent"] as? Int else {
                throw ProviderFailure.parseChanged
            }
            return ["usedPercent": usedPercent, "windowDurationMins": seconds / 60, "resetsAt": value["reset_at"]]
        }
        func bucketDict(_ value: [String: Any]?) throws -> [String: Any] {
            var result: [String: Any] = [:]
            if let primary = try windowDict(value?["primary_window"] as? [String: Any]) { result["primary"] = primary }
            if let secondary = try windowDict(value?["secondary_window"] as? [String: Any]) { result["secondary"] = secondary }
            for key in ["individual_limit", "individualLimit"] where value?[key] != nil {
                result["individualLimit"] = value![key]
            }
            return result
        }
        let rateLimit = usage["rate_limit"] as? [String: Any]
        var standard = try bucketDict(rateLimit)
        if let credits = usage["credits"] as? [String: Any] {
            var amount: [String: Any] = [
                "hasCredits": (credits["has_credits"] as? Bool) ?? false,
                "unlimited": (credits["unlimited"] as? Bool) ?? false,
            ]
            if let balance = Self.double(credits["balance"]) {
                amount["balance"] = NSDecimalNumber(string: String(balance), locale: Locale(identifier: "en_US_POSIX")).stringValue
            }
            standard["credits"] = amount
        }
        for key in ["individual_limit", "individualLimit"] where usage[key] != nil {
            standard["individualLimit"] = usage[key]
        }
        if standard["individualLimit"] == nil, let nested = rateLimit?["individual_limit"] ?? rateLimit?["individualLimit"] {
            standard["individualLimit"] = nested
        }
        var buckets = ["codex": standard]
        for extra in usage["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = (extra["metered_feature"] as? String) ?? (extra["limit_name"] as? String) ?? ""
            guard !name.isEmpty else { throw ProviderFailure.parseChanged }
            let key = name.lowercased().contains("spark") || name.lowercased().contains("bengalfox")
                ? "spark"
                : "extra-" + NativeProviderNormalizer.sha256(name).prefix(8)
            guard buckets[key] == nil else { throw ProviderFailure.parseChanged }
            buckets[key] = try bucketDict(extra["rate_limit"] as? [String: Any])
        }
        var response: [String: Any] = ["rateLimits": standard, "rateLimitsByLimitId": buckets]
        if let resetsData, let resets = try? JSONSerialization.jsonObject(with: resetsData) as? [String: Any],
           let availableCount = availableCount(from: resets) {
            var inventory: [String: Any] = ["availableCount": availableCount]
            if availableCount > 0, let expiry = nextExpiry(from: resets, now: now) {
                inventory["nextExpiresAt"] = Int64(expiry.timeIntervalSince1970)
            }
            response["rateLimitResetCredits"] = inventory
        }
        return try CodexNormalizer.normalize(JSONSerialization.data(withJSONObject: response),
                                             accountID: accountID, alias: alias, now: now, source: .officialAPI)
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let integer = value as? Int { return Double(integer) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func availableCount(from resets: [String: Any]) -> Int? {
        if let count = resets["available_count"] as? Int { return count }
        if let count = resets["availableCount"] as? Int { return count }
        if let credits = resets["credits"] as? [[String: Any]] {
            let now = Date()
            return credits.filter { credit in
                (credit["status"] as? String) == "available"
                    && ((credit["expires_at"] as? String).flatMap(NativeAPIParsing.date).map { $0 > now } ?? true)
            }.count
        }
        return nil
    }

    static func nextExpiry(from resets: [String: Any], now: Date) -> Date? {
        guard let credits = resets["credits"] as? [[String: Any]] else { return nil }
        return credits.compactMap { credit -> Date? in
            guard (credit["status"] as? String) == "available" else { return nil }
            guard let expiry = (credit["expires_at"] as? String).flatMap(NativeAPIParsing.date), expiry > now else { return nil }
            return expiry
        }.sorted().first
    }
}
