import Foundation

/// Claude subscription (Pro / Max) usage via the OAuth usage endpoint Claude
/// Code's `/usage` screen reads. The credential is a Claude Code OAuth access
/// token, pasted raw or as Claude Code's stored credentials JSON; it is never
/// refreshed here, so an expired token requires re-import. `/api/oauth/profile`
/// supplies the pinned account identity. Extra-usage spend is not read.
enum ClaudeUsageReader {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private struct UsageEnvelope: Decodable {
        struct Bucket: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        let five_hour: Bucket?
        let seven_day: Bucket?
        let seven_day_opus: Bucket?
        let seven_day_sonnet: Bucket?
    }

    private struct ProfileEnvelope: Decodable {
        struct Account: Decodable { let uuid: String?; let email: String? }
        struct Organization: Decodable { let uuid: String? }
        let account: Account?
        let organization: Organization?
    }

    private struct StoredCredentials: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .oauth, let token = accessToken(from: credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        return try await fetch(token: token)
    }

    static func fetch(token: String) async throws -> NativeUsage {
        let headers = ["Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"]
        let usageData: Data
        do {
            usageData = try await NativeHTTP.request("GET", usageURL, headers: headers).data
        } catch {
            if case NativeHTTP.Failure.httpStatus(401) = error { throw NativeProviderAPIError.credentialRejected }
            if case NativeHTTP.Failure.httpStatus(403) = error { throw NativeProviderAPIError.credentialRejected }
            throw error
        }
        let profileData = try? await NativeHTTP.request("GET", profileURL, headers: headers).data
        return try parse(usageData: usageData, profileData: profileData, token: token)
    }

    /// Accepts the bare `sk-ant-oat…` token or Claude Code's credentials JSON
    /// (`{"claudeAiOauth":{"accessToken":…}}`).
    static func accessToken(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String?
        if trimmed.hasPrefix("{") {
            token = (try? JSONDecoder().decode(StoredCredentials.self, from: Data(trimmed.utf8)))?.claudeAiOauth?.accessToken
        } else {
            token = trimmed
        }
        guard let token, token.count >= 8, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    static func parse(usageData: Data, profileData: Data?, token: String) throws -> NativeUsage {
        let data = try NativeHTTP.decode(UsageEnvelope.self, from: usageData)
        var usage = NativeUsage(updatedAt: Date())
        usage.primary = window("primary", data.five_hour, minutes: 300)
        usage.secondary = window("secondary", data.seven_day, minutes: 10_080)
        usage.extraWindows = [("seven_day_opus", data.seven_day_opus), ("seven_day_sonnet", data.seven_day_sonnet)]
            .compactMap { window($0.0, $0.1, minutes: 10_080) }
        if usage.primary == nil, usage.secondary == nil, usage.extraWindows.isEmpty { throw ProviderFailure.unsupported }

        if let profileData, let profile = try? NativeHTTP.decode(ProfileEnvelope.self, from: profileData),
           let accountID = profile.account?.uuid {
            usage.identity = .init(accountID: accountID, email: profile.account?.email,
                                   organization: profile.organization?.uuid)
        } else {
            usage.identitySeed = NativeAPIParsing.legacyCredentialSeed(provider: "claude", material: token)
        }
        return usage
    }

    /// `utilization` is already a 0–100 percentage; a null bucket (no plan
    /// access to that model) is dropped rather than shown as unused.
    private static func window(_ id: String, _ bucket: UsageEnvelope.Bucket?, minutes: Int) -> NativeUsage.Window? {
        guard let used = bucket?.utilization else { return nil }
        return .init(id: id, usedPercent: NativeAPIParsing.clampPercent(used), windowMinutes: minutes,
                     resetsAt: NativeAPIParsing.date(bucket?.resets_at))
    }
}
