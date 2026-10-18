import Foundation

/// GitHub Copilot quota via the same internal user endpoint the editor uses.
/// The credential is a GitHub OAuth token sent with the `token` scheme; the
/// premium-interactions and chat snapshots become the two quota windows and
/// `/user` supplies the pinned account identity. Cookie-based budget
/// enrichment is intentionally not implemented.
enum CopilotUsageReader {
    private static let quotaURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let identityURL = URL(string: "https://api.github.com/user")!

    private struct QuotaEnvelope: Decodable {
        struct Snapshot: Decodable {
            let entitlement: Double?
            let remaining: Double?
            let percentRemaining: Double?
            let unlimited: Bool?
            enum CodingKeys: String, CodingKey {
                case entitlement
                case remaining
                case percentRemaining = "percent_remaining"
                case unlimited
            }
        }
        struct Snapshots: Decodable {
            let premiumInteractions: Snapshot?
            let chat: Snapshot?
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                premiumInteractions = try values.decodeIfPresent(Snapshot.self, forKey: .premiumInteractions)
                    ?? values.decodeIfPresent(Snapshot.self, forKey: .premium)
                chat = try values.decodeIfPresent(Snapshot.self, forKey: .chat)
            }
            enum Keys: String, CodingKey {
                case premiumInteractions = "premium_interactions"
                case premium
                case chat
            }
        }
        // The endpoint answers with the user fields at the top level.
        let quotaSnapshots: Snapshots?
        let quotaResetDate: String?
        let copilotPlan: String?
        let tokenBasedBilling: Bool?
        enum CodingKeys: String, CodingKey {
            case quotaSnapshots = "quota_snapshots"
            case quotaResetDate = "quota_reset_date"
            case copilotPlan = "copilot_plan"
            case tokenBasedBilling = "token_based_billing"
        }
    }

    private struct IdentityEnvelope: Decodable {
        let id: Int64?
        let login: String?
    }

    private static let headers: [String: String] = [
        "Accept": "application/json",
        "Editor-Version": "vscode/1.96.2",
        "Editor-Plugin-Version": "copilot-chat/0.26.7",
        "User-Agent": "GitHubCopilotChat/0.26.7",
        "X-Github-Api-Version": "2025-04-01",
    ]

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        let token = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.kind == .apiKey, !token.isEmpty else { throw NativeProviderAPIError.credentialRejected }
        var quotaHeaders = headers
        quotaHeaders["Authorization"] = "token " + token
        let quotaData: Data
        do {
            let response = try await NativeHTTP.request("GET", quotaURL, headers: quotaHeaders)
            quotaData = response.data
        } catch {
            if case NativeHTTP.Failure.httpStatus(401) = error { throw NativeProviderAPIError.credentialRejected }
            if case NativeHTTP.Failure.httpStatus(403) = error { throw NativeProviderAPIError.credentialRejected }
            throw error
        }
        // Identity pins the connection even though quota responses carry none.
        var identityHeaders = headers
        identityHeaders["Authorization"] = "token " + token
        var identityData: Data?
        if let identityResponse = try? await NativeHTTP.request("GET", identityURL, headers: identityHeaders) {
            identityData = identityResponse.data
        }
        return try parse(quotaData: quotaData, identityData: identityData, token: token)
    }

    static func parse(quotaData: Data, identityData: Data?, token: String) throws -> NativeUsage {
        let data: QuotaEnvelope
        do { data = try NativeHTTP.decode(QuotaEnvelope.self, from: quotaData) }
        catch { throw error }
        // token_based_billing only explains empty snapshots; real quota windows
        // stay valid regardless of the flag, matching the released reader.
        let reset = NativeAPIParsing.date(data.quotaResetDate)
        var usage = NativeUsage(updatedAt: Date())
        usage.primary = window(from: data.quotaSnapshots?.premiumInteractions, resetsAt: reset)
        usage.secondary = window(from: data.quotaSnapshots?.chat, resetsAt: reset)
        if usage.primary == nil, usage.secondary == nil { throw ProviderFailure.unsupported }

        if let identityData,
           let identity = try? NativeHTTP.decode(IdentityEnvelope.self, from: identityData), let id = identity.id {
            usage.identity = .init(accountID: String(id), email: identity.login.map { $0 + "@users.noreply.github.com" })
        } else {
            usage.identitySeed = NativeAPIParsing.legacyCredentialsSeed(
                provider: "copilot", values: ["apiHost": "api.github.com", "token": token])
        }
        return usage
    }

    /// GitHub answers with percent-remaining (or entitlement+remaining).
    /// Unlimited seats, and token-billed seats whose entitlement and remaining
    /// both decoded as zero (even disguised as percent_remaining=100), carry no
    /// usable quota signal and are dropped instead of rendered as fake usage.
    private static func window(from snapshot: QuotaEnvelope.Snapshot?, resetsAt: Date?) -> NativeUsage.Window? {
        guard let snapshot else { return nil }
        if snapshot.unlimited == true { return nil }
        let hasPercent = snapshot.percentRemaining != nil
            || ((snapshot.entitlement ?? 0) > 0 && snapshot.remaining != nil)
        guard hasPercent else { return nil }
        let percentRemaining: Double
        if let explicit = snapshot.percentRemaining {
            percentRemaining = explicit
        } else {
            percentRemaining = (snapshot.remaining ?? 0) / (snapshot.entitlement ?? 1) * 100
        }
        if let entitlement = snapshot.entitlement, let remaining = snapshot.remaining,
           entitlement == 0, remaining == 0 {
            return nil
        }
        return .init(id: "quota", usedPercent: NativeAPIParsing.clampPercent(100 - percentRemaining),
                     windowMinutes: nil, resetsAt: resetsAt)
    }
}
