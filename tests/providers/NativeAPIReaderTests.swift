import QuotaCore
@testable import QuotaProviders
import XCTest

/// Synthetic-response coverage for the self-developed API readers. Field
/// names mirror the live provider contracts; no test touches the network.
final class NativeAPIReaderTests: XCTestCase {
    private func credential(_ kind: NativeProviderCredential.Kind = .apiKey, _ value: String = "credential-value-12345", region: String? = nil) -> NativeProviderCredential {
        NativeProviderCredential(kind: kind, value: value, region: region)
    }

    // MARK: - Amp

    func testAmpSubscriptionFreeAndCreditsParse() throws {
        let text = """
        Signed in as me@example.com (ACME)
        Subscription Pro: 73.2% other usage and 81.5% orb usage remaining - resets upon renewal in 12 days
        Amp Free: 42% remaining today (resets daily)
        Individual credits: $13.37 remaining
        """
        let usage = try AmpUsageReader.parse(text, now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(usage.identity.email, "me@example.com")
        XCTAssertEqual(usage.identity.organization, "ACME")
        let primary = try XCTUnwrap(usage.primary)
        XCTAssertEqual(primary.usedPercent, 26.8, accuracy: 0.001)
        XCTAssertEqual(primary.windowMinutes, 43_200)
        let secondary = try XCTUnwrap(usage.secondary)
        XCTAssertEqual(secondary.usedPercent, 18.5, accuracy: 0.001)
        let free = try XCTUnwrap(usage.extraWindows.first)
        XCTAssertEqual(free.id, "amp-free")
        XCTAssertEqual(free.usedPercent, 58, accuracy: 0.001)
        XCTAssertEqual(free.windowMinutes, 24 * 60)
        let cost = try XCTUnwrap(usage.cost)
        XCTAssertEqual(cost.balance ?? -1, 13.37, accuracy: 0.001)
        XCTAssertNil(cost.freeBalance)
        XCTAssertEqual(cost.currency, "USD")
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "amp", alias: "Amp", source: .officialAPI)
        XCTAssertEqual(normalized.windows.count, 4)
    }

    func testAmpFreeDollarFormAndSignedOut() throws {
        let usage = try AmpUsageReader.parse(
            "Signed in as a@b.c\nAmp Free: $3.20 / $10.00 remaining (replenishes +$1.60/hour)", now: Date())
        let free = try XCTUnwrap(usage.extraWindows.first)
        XCTAssertEqual(free.usedPercent, 68, accuracy: 0.001)
        XCTAssertEqual(free.windowMinutes, 360)
        XCTAssertThrowsError(try AmpUsageReader.parse("Please log in to view usage."))
    }

    func testAmpCreditsFoldFreeAllowanceSplitsPurchasedFromFree() throws {
        let usage = try AmpUsageReader.parse(
            "Signed in as user@example.com\nIndividual credits: $10 remaining (includes $5 Amp Free remaining today; resets daily) - https://ampcode.com/settings",
            now: Date(timeIntervalSince1970: 1_760_000_000))
        let cost = try XCTUnwrap(usage.cost)
        // The headline number folds the daily free credit in; the balance the
        // card shows must be the purchased share only.
        XCTAssertEqual(cost.balance ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(cost.freeBalance ?? -1, 5, accuracy: 0.001)
        XCTAssertNotNil(cost.freeResetsAt)
        XCTAssertNil(usage.primary)
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "amp", alias: "Amp", source: .officialAPI)
        XCTAssertEqual(normalized.windows.count, 2)
        XCTAssertEqual(normalized.windows.map(\.quotaKey), ["balance", "free-balance"])
        XCTAssertEqual(normalized.windows.map(\.amount), ["5", "5"])
        XCTAssertEqual(normalized.windows.last?.currency, "USD")
        XCTAssertNotNil(normalized.windows.last?.window.resetsAt)
        XCTAssertNil(normalized.windows.first?.window.resetsAt)
    }

    // MARK: - OpenRouter

    func testOpenRouterCreditsAndKeyLimit() throws {
        let credits = Data(#"{"data":{"total_credits":50,"total_usage":20}}"#.utf8)
        let key = Data(#"{"data":{"limit":100,"limit_remaining":75}}"#.utf8)
        let usage = try OpenRouterUsageReader.parse(creditsData: credits, keyData: key, apiKey: "sk-or-v1-testkey")
        let primary = try XCTUnwrap(usage.primary)
        XCTAssertEqual(primary.usedPercent, 25, accuracy: 0.001)
        let cost = try XCTUnwrap(usage.cost)
        XCTAssertEqual(cost.balance ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(cost.used, 0, accuracy: 0.001)
        XCTAssertNotNil(usage.identitySeed)
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "openrouter", alias: "OpenRouter", source: .officialAPI)
        XCTAssertEqual(normalized.windows.count, 2)
    }

    func testOpenRouterCreditsRequireData() {
        XCTAssertThrowsError(try OpenRouterUsageReader.parse(
            creditsData: Data(#"{"error":"nope"}"#.utf8), keyData: nil, apiKey: "sk-or-v1-testkey"))
    }

    // MARK: - Copilot

    func testCopilotPremiumAndChatWindowsWithIdentity() throws {
        let quota = Data(#"{"copilot_plan":"pro","quota_reset_date":"2026-10-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":210,"percent_remaining":70},"chat":{"unlimited":true}}}"#.utf8)
        let identity = Data(#"{"id":123456,"login":"octocat"}"#.utf8)
        let usage = try CopilotUsageReader.parse(quotaData: quota, identityData: identity, token: "gho-testtoken")
        let primary = try XCTUnwrap(usage.primary)
        XCTAssertEqual(primary.usedPercent, 30, accuracy: 0.001)
        XCTAssertEqual(primary.resetsAt?.timeIntervalSince1970 ?? 0, 1_790_812_800, accuracy: 1)
        XCTAssertNil(usage.secondary, "an unlimited chat seat must not become a window")
        XCTAssertEqual(usage.identity.accountID, "123456")
    }

    func testCopilotPlaceholderSeatsAreDroppedNotZeroPercent() throws {
        let quota = Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}"#.utf8)
        XCTAssertThrowsError(try CopilotUsageReader.parse(
            quotaData: quota, identityData: nil, token: "gho-testtoken"))
        // The token-billing flag alone must not reject an account that reports
        // real quota windows (individual plans can carry it).
        let tokenBilled = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":1}}}"#.utf8)
        let usage = try CopilotUsageReader.parse(quotaData: tokenBilled, identityData: nil, token: "gho-testtoken")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 99.667, accuracy: 0.01)
        // Zero-entitlement zero-remaining placeholders stay dropped even when
        // percent_remaining pretends to be 100.
        let disguised = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100}}}"#.utf8)
        XCTAssertThrowsError(try CopilotUsageReader.parse(
            quotaData: disguised, identityData: nil, token: "gho-testtoken"))
    }

    // MARK: - z.ai

    func testZaiWindowsOrderAndMCPExtraAndBalance() throws {
        let quota = Data("""
        {"success":true,"code":200,"data":{"planName":"GLM-4.7","limits":[
            {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":10,"nextResetTime":1790000000000},
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":30,"nextResetTime":1790000000000},
            {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":55,"nextResetTime":1790000000000}
        ]}}
        """.utf8)
        let balance = Data(#"{"success":true,"data":{"availableBalance":42.5}}"#.utf8)
        let credential = credential(.apiKey, "zai-key-value", region: "bigmodel-cn")
        let usage = try ZaiUsageReader.parse(quotaData: quota, balanceData: balance, seed: ZaiUsageReader.seed(apiKey: "zai-key-value", region: "bigmodel-cn", credential: credential))
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.windowMinutes, 10_080)
        let mcp = try XCTUnwrap(usage.extraWindows.first { $0.id == "zai-mcp" })
        XCTAssertEqual(mcp.usedPercent, 55, accuracy: 0.001)
        XCTAssertEqual(mcp.windowMinutes, 43_200)
        XCTAssertEqual(usage.cost?.currency, "CNY")
        XCTAssertEqual(usage.cost?.balance ?? -1, 42.5, accuracy: 0.001)
    }

    func testZaiRejectsFailureEnvelope() {
        let quota = Data(#"{"success":false,"code":401,"msg":"bad key"}"#.utf8)
        XCTAssertThrowsError(try ZaiUsageReader.parse(quotaData: quota, balanceData: nil, seed: "seed"))
    }

    func testZaiTeamScopeRequiresOrganizationAndProjectTogether() throws {
        let personal = credential(.apiKey, "zai-key-value", region: "global")
        let personalRequest = try ZaiUsageReader.requestHeaders(for: personal, apiKey: personal.value)
        XCTAssertFalse(personalRequest.0)
        XCTAssertNil(personalRequest.1["Bigmodel-Organization"])
        XCTAssertNil(personalRequest.1["Bigmodel-Project"])

        let team = NativeProviderCredential(kind: .apiKey, value: "zai-key-value",
            organizationID: "org-1", workspaceID: "project-1", region: "global")
        let teamRequest = try ZaiUsageReader.requestHeaders(for: team, apiKey: team.value)
        XCTAssertTrue(teamRequest.0)
        XCTAssertEqual(teamRequest.1["Bigmodel-Organization"], "org-1")
        XCTAssertEqual(teamRequest.1["Bigmodel-Project"], "project-1")

        for partial in [
            NativeProviderCredential(kind: .apiKey, value: "zai-key-value", organizationID: "org-1", region: "global"),
            NativeProviderCredential(kind: .apiKey, value: "zai-key-value", workspaceID: "project-1", region: "global"),
        ] {
            XCTAssertThrowsError(try ZaiUsageReader.requestHeaders(for: partial, apiKey: partial.value))
        }
    }

    func testZaiAPIQuotaDoesNotGainAmbientResetCards() throws {
        let quota = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":30,"nextResetTime":1790000000000}]}}"#.utf8)
        let usage = try ZaiUsageReader.parse(quotaData: quota, balanceData: nil, seed: String(repeating: "a", count: 64))
        XCTAssertFalse(usage.extraWindows.contains { $0.id.hasPrefix("rate-limit-reset") })
        let windows = try NativeProviderNormalizer.normalize(
            usage, providerID: "zai", alias: "Plan", source: .officialAPI).windows
        XCTAssertFalse(windows.contains { $0.quotaKey.hasPrefix("rate-limit-reset") })
    }

    // MARK: - Grok

    func testGrokPublishedPercentAndPeriod() throws {
        let data = Data(#"{"config":{"creditUsagePercent":37.5,"currentPeriod":{"end":"2026-09-30T00:00:00Z"},"subscriptionTier":"supergrok"}}"#.utf8)
        let usage = try GrokUsageReader.parse(data: data, identitySeed: "seed")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 37.5, accuracy: 0.001)
        XCTAssertNotNil(usage.primary?.resetsAt)
    }

    func testGrokOnDemandFallbackAndTokenNormalization() throws {
        let data = Data(#"{"config":{"onDemandCap":{"val":10000},"onDemandUsed":{"val":2500},"billingPeriodEnd":"2026-09-30T00:00:00Z"}}"#.utf8)
        let usage = try GrokUsageReader.parse(data: data, identitySeed: "seed")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertNil(GrokUsageReader.normalizedToken("cookie: sso=1"))
        XCTAssertNil(GrokUsageReader.normalizedToken("xai-management-key"))
        XCTAssertEqual(GrokUsageReader.normalizedToken("bearer abc-def"), "abc-def")
    }

    // MARK: - Grok bot rate limits

    func testGrokBotWindowParsesQueriesAndRollingReset() throws {
        let data = Data(#"{"remainingQueries":8,"totalQueries":20,"windowSizeSeconds":7200}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = try GrokBotUsageReader.parse(data: data, pool: "auto", now: now)
        XCTAssertEqual(window.id, "bot-auto")
        XCTAssertEqual(window.usedPercent, 60, accuracy: 0.001)
        XCTAssertEqual(window.windowMinutes, 120)
        XCTAssertEqual(window.resetsAt, now.addingTimeInterval(7_200))
        let windows = try NativeProviderNormalizer.normalize(
            NativeUsage(extraWindows: [window], identitySeed: String(repeating: "a", count: 64)),
            providerID: "grok", alias: "Grok", source: .officialAPI).windows
        XCTAssertEqual(windows.first?.quotaKey, "bot-auto")
        XCTAssertEqual(windows.first?.shortDisplayName.hasPrefix("Auto"), true)
    }

    func testGrokBotWaitTimeOverridesWindowAnchorAndDefaultsApply() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exhausted = try GrokBotUsageReader.parse(
            data: Data(#"{"remainingQueries":0,"totalQueries":7,"waitTimeSeconds":540}"#.utf8),
            pool: "fast", now: now)
        XCTAssertEqual(exhausted.usedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(exhausted.resetsAt, now.addingTimeInterval(540))
        let defaulted = try GrokBotUsageReader.parse(
            data: Data(#"{"remainingQueries":3,"totalQueries":30,"windowSizeSeconds":0}"#.utf8),
            pool: "heavy", now: now)
        XCTAssertEqual(defaulted.windowMinutes, 120)
        XCTAssertEqual(defaulted.resetsAt, now.addingTimeInterval(7_200))
    }

    func testGrokBotParseRejectsMissingTotalOrNegativeRemaining() {
        XCTAssertThrowsError(try GrokBotUsageReader.parse(data: Data(#"{"remainingQueries":1}"#.utf8), pool: "auto"))
        XCTAssertThrowsError(try GrokBotUsageReader.parse(data: Data(#"{"remainingQueries":-1,"totalQueries":20}"#.utf8), pool: "auto"))
        XCTAssertThrowsError(try GrokBotUsageReader.parse(data: Data("{}".utf8), pool: "auto"))
    }

    func testGrokBotSessionCookieNormalization() {
        let full = GrokBotUsageReader.sessionCookies(from: "Cookie: cf_clearance=cf1; sso=jwt-a; other=x; sso-rw=jwt-b;")
        XCTAssertEqual(full, "sso=jwt-a; sso-rw=jwt-b; cf_clearance=cf1")
        XCTAssertEqual(GrokBotUsageReader.sessionCookies(from: "jwt-a"), "sso=jwt-a; sso-rw=jwt-a")
        XCTAssertEqual(GrokBotUsageReader.sessionCookies(from: "sso-rw=jwt-b"), "sso=jwt-b; sso-rw=jwt-b")
        XCTAssertNil(GrokBotUsageReader.sessionCookies(from: "other=1; session=2"))
        XCTAssertNil(GrokBotUsageReader.sessionCookies(from: "xai-management-key"))
    }

    func testGrokBotHeadersCarrySessionAndRequestID() {
        let headers = GrokBotUsageReader.requestHeaders(cookies: "sso=a; sso-rw=a", requestID: "req-1")
        XCTAssertEqual(headers["Cookie"], "sso=a; sso-rw=a")
        XCTAssertEqual(headers["x-xai-request-id"], "req-1")
        XCTAssertEqual(headers["Origin"], "https://grok.com")
        XCTAssertNotNil(headers["x-statsig-id"])
    }

    func testGrokBotFetchRejectsNonCookieCredential() async {
        do {
            _ = try await GrokBotUsageReader.fetch(credential(.apiKey, "token-value-1"), now: Date())
            XCTFail("apiKey credential must not reach the bot channel")
        } catch let error as NativeProviderAPIError {
            guard case .credentialRejected = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testGrokCatalogAcceptsCookieAndKeyCredentials() {
        XCTAssertEqual(NativeProviderCatalog.supportedCredentialKinds(providerID: "grok"), [.apiKey, .cookie])
    }

    func testGrokBotExpertPoolParsesAndDisplays() throws {
        XCTAssertEqual(GrokBotUsageReader.pools, ["auto", "fast", "expert", "heavy"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expert = try GrokBotUsageReader.parse(
            data: Data(#"{"remainingQueries":2,"totalQueries":10,"windowSizeSeconds":7200}"#.utf8),
            pool: "expert", now: now)
        XCTAssertEqual(expert.id, "bot-expert")
        XCTAssertEqual(expert.usedPercent, 80, accuracy: 0.001)
        let windows = try NativeProviderNormalizer.normalize(
            NativeUsage(extraWindows: [expert], identitySeed: String(repeating: "a", count: 64)),
            providerID: "grok", alias: "Grok", source: .officialAPI).windows
        XCTAssertEqual(windows.first?.shortDisplayName.hasPrefix("Expert"), true)
    }

    // MARK: - Claude

    func testClaudeWindowsIdentityAndNullBuckets() throws {
        let usageData = Data(#"{"five_hour":{"utilization":23.0,"resets_at":"2026-09-24T04:59:59.943648+00:00"},"seven_day":{"utilization":61.5,"resets_at":"2026-09-28T03:59:59.943679+00:00"},"seven_day_opus":null,"seven_day_sonnet":{"utilization":10,"resets_at":null},"extra_usage":{"is_enabled":false}}"#.utf8)
        let profile = Data(#"{"account":{"uuid":"acc-1","email":"me@example.com"},"organization":{"uuid":"org-1"}}"#.utf8)
        let usage = try ClaudeUsageReader.parse(usageData: usageData, profileData: profile, token: "tok")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 23, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertNotNil(usage.primary?.resetsAt, "microsecond ISO8601 reset must parse")
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 61.5, accuracy: 0.001)
        XCTAssertEqual(usage.extraWindows.map(\.id), ["seven_day_sonnet"])
        XCTAssertEqual(usage.identity.accountID, "acc-1")
        XCTAssertEqual(usage.identity.organization, "org-1")
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "claude", alias: "Claude", source: .officialAPI)
        XCTAssertEqual(result.windows.count, 3)
        XCTAssertEqual(result.windows.first { $0.quotaKey == "seven_day_sonnet" }?.shortDisplayName.hasPrefix("Sonnet"), true)
    }

    func testClaudeTokenFormsAndEmptyUsage() throws {
        XCTAssertEqual(ClaudeUsageReader.accessToken(from: "  sk-ant-oat01-abc\n"), "sk-ant-oat01-abc")
        XCTAssertEqual(ClaudeUsageReader.accessToken(from: #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-xyz","refreshToken":"r"}}"#), "sk-ant-oat01-xyz")
        XCTAssertNil(ClaudeUsageReader.accessToken(from: #"{"other":{}}"#))
        XCTAssertNil(ClaudeUsageReader.accessToken(from: "Bearer sk-ant-oat01-abc"))
        XCTAssertThrowsError(try ClaudeUsageReader.parse(usageData: Data(#"{"five_hour":null}"#.utf8), profileData: nil, token: "tok"))
        let seeded = try ClaudeUsageReader.parse(usageData: Data(#"{"seven_day":{"utilization":5}}"#.utf8), profileData: nil, token: "tok")
        XCTAssertNotNil(seeded.identitySeed)
    }

    // MARK: - Antigravity

    private func antigravityStored(idToken: String?) -> AntigravityCredentialImport.StoredOAuth {
        .init(accessToken: "token-value", projectID: "proj-1", idToken: idToken,
              email: nil, expiryDateMilliseconds: 4_102_444_800_000)
    }

    func testAntigravityPoolsExtrasAndEmailClaim() throws {
        let models = Data("""
        {"models":{
            "gemini-3-pro":{"quotaInfo":{"remainingFraction":0.7,"resetTime":"2026-09-20T00:00:00Z"}},
            "claude-opus-4":{"quotaInfo":{"remainingFraction":0.4}},
            "gemini-image-lite":{"quotaInfo":{"remainingFraction":0.1}}
        }}
        """.utf8)
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let idToken = "aa.\(payload).bb"
        let usage = try AntigravityUsageReader.parse(
            modelsData: models, bucketsData: nil, stored: antigravityStored(idToken: idToken))
        let primary = try XCTUnwrap(usage.primary)
        XCTAssertEqual(primary.usedPercent, 30, accuracy: 0.001, "gemini pool takes the most-used model")
        let secondary = try XCTUnwrap(usage.secondary)
        XCTAssertEqual(secondary.usedPercent, 60, accuracy: 0.001)
        XCTAssertEqual(usage.identity.email, "me@example.com")
        XCTAssertEqual(usage.identity.organization, "proj-1")
        XCTAssertFalse(usage.extraWindows.contains { $0.id.contains("lite") })
    }

    func testAntigravityImportAcceptsBothKeySpellingsAndRejectsExpiry() throws {
        let snake = Data(#"{"access_token":"tok","project_id":"p1","expiry_date":4102444800000}"#.utf8)
        let imported = try AntigravityCredentialImport.credential(from: snake)
        XCTAssertEqual(imported.kind, .oauth)
        XCTAssertTrue(imported.value.contains("p1"))
        let camel = Data(#"{"accessToken":"tok","projectId":"p2"}"#.utf8)
        XCTAssertEqual(try AntigravityCredentialImport.credential(from: camel).value.contains("p2"), true)
        let expired = Data(#"{"access_token":"tok","project_id":"p1","expiry_date":1000}"#.utf8)
        XCTAssertThrowsError(try AntigravityCredentialImport.credential(from: expired))
        let missingProject = Data(#"{"access_token":"tok"}"#.utf8)
        XCTAssertThrowsError(try AntigravityCredentialImport.credential(from: missingProject))
    }

    // MARK: - Factory

    func testFactoryBillingLimitsAndIdentity() throws {
        let auth = Data(#"{"userProfile":{"id":"user-1","email":"me@example.com"},"organization":{"id":"org-1","name":"ACME"}}"#.utf8)
        let limits = Data("""
        {"data":{"usesTokenRateLimitsBilling":true,
          "standard":{"fiveHour":{"usedPercent":42,"secondsRemaining":3600},
                      "weekly":{"usedPercent":10,"windowEnd":1790000000},
                      "monthly":null},
          "core":{"fiveHour":{"usedPercent":5}},
          "extraUsageBalanceCents":1234}}
        """.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: limits, usageData: nil, credential: credential())
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertEqual(usage.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(usage.cost?.balance ?? -1, 12.34, accuracy: 0.001)
        XCTAssertEqual(usage.identity.accountID, "user-1")
        XCTAssertTrue(usage.extraWindows.contains { $0.id == "core-5h" })
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "factory", alias: "Droid", source: .officialAPI)
        XCTAssertFalse(normalized.windows.isEmpty)
    }

    func testFactoryTopLevelLimitsShape() throws {
        // The endpoint exposes the flag and balance at the top level with the
        // groups under `limits`; ISO8601 window ends, zero-use windows.
        let auth = Data(#"{"userProfile":{"email":"me@example.com","workosUser":{"id":"user_01K"}},"organization":{"id":"org-1","name":"ACME"}}"#.utf8)
        let limits = Data("""
        {"usesTokenRateLimitsBilling":true,
          "limits":{"standard":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                                 "weekly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                                 "monthly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null}},
                    "core":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                            "weekly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                            "monthly":{"usedPercent":20,"windowEnd":"2026-09-24T00:12:53.943Z","secondsRemaining":782129}}},
          "overagePreference":"droidCore","canManageOverage":true,
          "extraUsageBalanceCents":0,"extraUsageAllowed":true}
        """.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: limits, usageData: nil, credential: credential())
        XCTAssertNotNil(usage.primary, "standard windows should parse from the top-level shape")
        XCTAssertEqual(usage.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(usage.tertiary?.windowMinutes, nil)
        XCTAssertTrue(usage.extraWindows.contains { $0.id == "core-monthly" && $0.usedPercent == 20 })
        XCTAssertNotNil(usage.extraWindows.first { $0.id == "core-monthly" }?.resetsAt)
        XCTAssertEqual(usage.identity.accountID, "user_01K")
        XCTAssertEqual(usage.identity.email, "me@example.com")
        XCTAssertTrue(FactoryUsageReader.hasWindows(limitsData: limits))
    }

    func testFactoryLegacyUsageFallback() throws {
        let auth = Data(#"{"userProfile":{"id":"user-1"}}"#.utf8)
        let legacy = Data("""
        {"data":{"usage":{"startDate":1788000000000,"endDate":1790600000000,
          "userTokens":100,"orgTotalTokensUsed":250,"totalAllowance":1000},"userId":"user-1"}}
        """.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: nil, usageData: legacy, credential: credential())
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.resetsAt?.timeIntervalSince1970 ?? 0, 1_790_600_000, accuracy: 1)
    }

    func testFactoryComputeUsageWindow() throws {
        let auth = Data(#"{"userProfile":{"id":"user-1"}}"#.utf8)
        let limits = Data("""
        {"usesTokenRateLimitsBilling":true,
          "limits":{"standard":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null}},
                    "core":null}}
        """.utf8)
        let compute = Data(#"{"orgUsageMs":5400000,"limitMs":72000000,"periodEnd":"2027-07-13T22:57:00.000Z","overageAllowed":false}"#.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: limits, usageData: nil,
                                                 computeData: compute, credential: credential())
        let computeWindow = usage.extraWindows.first { $0.id == "compute" }
        XCTAssertNotNil(computeWindow, "20.0h compute limit with 1.5h used should yield a window")
        XCTAssertEqual(computeWindow?.usedPercent ?? -1, 7.5, accuracy: 0.001)
        XCTAssertNotNil(computeWindow?.resetsAt)
    }

    func testFactoryComputeUsageNullLimitIsSkipped() throws {
        let auth = Data(#"{"userProfile":{"id":"user-1"}}"#.utf8)
        let limits = Data("""
        {"usesTokenRateLimitsBilling":true,
          "limits":{"standard":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null}},
                    "core":null}}
        """.utf8)
        let compute = Data(#"{"orgUsageMs":null,"limitMs":null,"periodEnd":null}"#.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: limits, usageData: nil,
                                                 computeData: compute, credential: credential())
        XCTAssertFalse(usage.extraWindows.contains { $0.id == "compute" },
                       "a null compute limit means the plan has no managed-computers section")
    }

    func testFactoryComputeOnlyResponseStillParses() throws {
        // Plans whose token-rate-limit groups are all null must not fail the
        // whole fetch when the compute endpoint does answer.
        let auth = Data(#"{"userProfile":{"id":"user-1"}}"#.utf8)
        let compute = Data(#"{"orgUsageMs":0,"limitMs":72000000,"periodEnd":null}"#.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: nil, usageData: nil,
                                                 computeData: compute, credential: credential())
        XCTAssertEqual(usage.extraWindows.first { $0.id == "compute" }?.usedPercent ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Manus
    func testManusCreditBucketsParse() throws {
        let data = Data(#"{"data":{"totalCredits":1200,"proMonthlyCredits":1000,"periodicCredits":250,"maxRefreshCredits":100,"refreshCredits":25,"nextRefreshTime":"2026-09-20T00:00:00Z"}}"#.utf8)
        let usage = try ManusUsageReader.parse(data: data, session: "session-token")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertNotNil(usage.secondary?.resetsAt)
        XCTAssertEqual(ManusUsageReader.sessionID(from: "Cookie: session_id=abc123; other=1"), "abc123")
        XCTAssertEqual(ManusUsageReader.sessionID(from: "raw-session-token"), "raw-session-token")
        XCTAssertNil(ManusUsageReader.sessionID(from: "a=1; b=2"))
    }

    func testManusRejectsEnvelopeWithoutCreditFields() {
        XCTAssertThrowsError(try ManusUsageReader.parse(
            data: Data(#"{"data":{"message":"unauthorized"}}"#.utf8), session: "session-token"))
    }

    // MARK: - DeepSeek

    func testDeepSeekAPIBalancePicksUSDRow() throws {
        let balance = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"10.00"},{"currency":"USD","total_balance":"5.50"}]}"#.utf8)
        let usage = try DeepSeekUsageReader.parse(balanceData: balance, summaryData: nil, seedMaterial: "sk-test")
        XCTAssertEqual(usage.cost?.currency, "USD")
        XCTAssertEqual(usage.cost?.balance ?? -1, 5.50, accuracy: 0.001)
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "deepseek", alias: "DeepSeek", source: .officialAPI)
        XCTAssertEqual(normalized.windows.count, 1)
        XCTAssertEqual(normalized.windows.first?.unit, .money)
    }

    func testDeepSeekPlatformWalletSummaryAndBadCode() throws {
        let summary = Data("""
        {"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"balance":"20.5","currency":"CNY"}],"bonus_wallets":[{"balance":1.5,"currency":"CNY"}]}}}
        """.utf8)
        let usage = try DeepSeekUsageReader.parse(balanceData: nil, summaryData: summary, seedMaterial: "platform-token-value-123")
        XCTAssertEqual(usage.cost?.balance ?? -1, 22.0, accuracy: 0.001)
        let badCode = Data(#"{"code":0,"data":{"biz_code":40002,"biz_data":null}}"#.utf8)
        XCTAssertThrowsError(try DeepSeekUsageReader.parse(balanceData: nil, summaryData: badCode, seedMaterial: "platform-token-value-123"))
    }

    // MARK: - OpenCodeGo

    func testOpenCodeGoWindowsAndRenewalExclusion() throws {
        let usageData = Data("""
        {"usage":{"rolling":{"usagePercent":40,"resetInSec":3600},
                  "weekly":{"percent":10,"resetAt":1790000000},
                  "monthly":{"used":30,"limit":100},
                  "renewAt":"2026-10-01T00:00:00Z"}}
        """.utf8)
        let usage = try OpenCodeGoUsageReader.parse(usageData: usageData, balanceData: nil, seedMaterial: "zen-key")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(usage.tertiary?.usedPercent ?? -1, 30, accuracy: 0.001)
        // The renewal row is dropped by the normalizer, never shown as quota.
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "opencodego", alias: "OpenCode Go", source: .officialAPI)
        XCTAssertFalse(normalized.windows.contains { $0.quotaKey == "renewal" })
    }

    func testOpenCodeGoZenBalanceAndCookieFilter() throws {
        let billing = Data(#"{"result":{"customerID":"cus_1","balance":25000000000}}"#.utf8)
        var usage = NativeUsage(updatedAt: Date())
        OpenCodeGoUsageReader.applyZenBalanceForTesting(billing, to: &usage)
        XCTAssertEqual(usage.cost?.balance ?? -1, 250, accuracy: 0.001)
        XCTAssertEqual(usage.cost?.currency, "USD")
        XCTAssertEqual(OpenCodeGoUsageReader.requestCookieHeader(from: "auth=abc; other=1; __Host-auth=def"), "auth=abc; __Host-auth=def")
        XCTAssertNil(OpenCodeGoUsageReader.requestCookieHeader(from: "session=abc"))
        XCTAssertEqual(OpenCodeGoUsageReader.firstWorkspaceID(in: Data(#"{"workspaces":[{"id":"wrk_123"}]}"#.utf8)), "wrk_123")
    }

    // MARK: - Legacy fingerprint compatibility

    /// The seed digests pin migrated connections: their stored
    /// expectedIdentity was produced with exactly these inputs, so the
    /// formulas (including key names and field order) are load-bearing.
    func testLegacySeedFormulasMatchReleasedDigests() {
        XCTAssertEqual(
            NativeAPIParsing.legacyCredentialSeed(provider: "deepseek", material: "KEY"),
            "dcc1cccd35108434d4ef7e6007be12656811d4dc7d77d80fd468bdf24c807611")
        XCTAssertEqual(
            NativeAPIParsing.legacyCredentialsSeed(provider: "zai", values: ["Z_AI_API_KEY": "KEY"]),
            "7b3f26872839de0380c306efa33047af41bc459f17df02ff42b47502f18a1bc1")
        XCTAssertEqual(
            NativeAPIParsing.legacyCredentialsSeed(provider: "copilot", values: ["token": "TOKEN", "apiHost": "api.github.com"]),
            "122ac20388b724b2ddbd93c457f4bceeed9a6a1b4f2f3b9767379272e7198d5e")
    }

    func testSeedOnlyFingerprintMirrorsReleasedNormalizerChain() throws {
        // automatic-source fingerprint chain for providers whose API carries
        // no self-reported identity.
        let seed = NativeAPIParsing.legacyCredentialSeed(provider: "deepseek", material: "KEY")
        let usage = NativeUsage(
            cost: .init(used: 0, limit: 0, balance: 1, currency: "CNY", period: "Balance"),
            identitySeed: seed, updatedAt: Date())
        let result = try NativeProviderNormalizer.normalize(
            usage, providerID: "deepseek", alias: "DeepSeek", source: .officialAPI)
        XCTAssertEqual(
            result.identityFingerprint,
            NativeProviderNormalizer.sha256("automatic-source\ndeepseek\n" + seed))
    }

    func testZaiSeedMaterialIncludesScopeFields() {
        let personal = credential(.apiKey, "KEY", region: "bigmodel-cn")
        XCTAssertEqual(
            ZaiUsageReader.seed(apiKey: "KEY", region: "bigmodel-cn", credential: personal),
            NativeProviderNormalizer.sha256("credential\nzai\nZ_AI_API_KEY=KEY\nscope:region=bigmodel-cn\nscope:usageScope=personal"))
        let team = NativeProviderCredential(kind: .apiKey, value: "KEY", organizationID: "org1", workspaceID: "proj1", region: "global")
        XCTAssertEqual(
            ZaiUsageReader.seed(apiKey: "KEY", region: "global", credential: team),
            NativeProviderNormalizer.sha256("credential\nzai\nZ_AI_API_KEY=KEY\nscope:organization=org1\nscope:project=proj1\nscope:region=global\nscope:usageScope=team"))
    }

    // MARK: - WorkBuddy

    private func workbuddyAccount(code: String, resource: String, status: Int,
                                  start: String, end: String, total: String, used: String) -> String {
        """
        {"PackageCode":"\(code)","ResourceId":"\(resource)","Uin":"100000000000","Status":\(status),\
        "CycleStartTime":"\(start)","CycleEndTime":"\(end)",\
        "CycleCapacitySizePrecise":"\(total)","CycleCapacityUsedPrecise":"\(used)"}
        """
    }

    private func workbuddyEnvelope(_ accounts: [String]) -> Data {
        Data(#"{"data":{"Response":{"Data":{"Accounts":["#.utf8)
            + Data(accounts.joined(separator: ",").utf8)
            + Data(#"]}}}}"#.utf8)
    }

    func testWorkBuddyPackagesMapToOrderedWindows() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let usage = try WorkBuddyUsageReader.parse(workbuddyEnvelope([
            // The granted pack is listed first but ranks behind the plan.
            workbuddyAccount(code: "TCACA_code_007_nzdH5h4Nl0", resource: "codebuddy-activity", status: 0,
                             start: "2026-09-24 22:46:46", end: "2026-10-24 22:46:45", total: "100", used: "0"),
            workbuddyAccount(code: "TCACA_code_008_cfWoLwvjU4", resource: "codebuddy-plan", status: 0,
                             start: "2026-09-01 00:00:00", end: "2026-09-30 23:59:59", total: "1000", used: "250"),
        ]), now: now)
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 25, accuracy: 0.001)
        func local(_ comps: (Int, Int, Int, Int, Int, Int)) -> Date? {
            var expected = DateComponents()
            expected.year = comps.0; expected.month = comps.1; expected.day = comps.2
            expected.hour = comps.3; expected.minute = comps.4; expected.second = comps.5
            return Calendar.current.date(from: expected)
        }
        // The billing API's naive timestamps parse as local time.
        XCTAssertEqual(usage.primary?.resetsAt, local((2026, 9, 30, 23, 59, 59)))
        XCTAssertEqual(usage.primary?.windowMinutes,
                       local((2026, 9, 30, 23, 59, 59)).flatMap { end in
                           local((2026, 9, 1, 0, 0, 0)).map { Int(end.timeIntervalSince($0) / 60) }
                       })
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(usage.identity.accountID, "100000000000")
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "workbuddy", alias: "WorkBuddy", source: .officialAPI)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.accountID, "native-" + String(
            NativeProviderNormalizer.sha256("automatic-account-id\nworkbuddy\n100000000000").prefix(32)))
    }

    func testWorkBuddyFiltersRefundedAndExpiredPackages() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let usage = try WorkBuddyUsageReader.parse(workbuddyEnvelope([
            workbuddyAccount(code: "TCACA_code_009_0XmEQc2xOf", resource: "codebuddy-refunded", status: 1,
                             start: "2026-09-01 00:00:00", end: "2026-09-30 00:00:00", total: "100", used: "0"),
            workbuddyAccount(code: "TCACA_code_029_6wCGEWquYy", resource: "codebuddy-expired", status: 0,
                             start: "2026-01-01 00:00:00", end: "2026-02-01 00:00:00", total: "100", used: "0"),
            workbuddyAccount(code: "TCACA_code_028_NtpWi0jzXs", resource: "codebuddy-usedup", status: 3,
                             start: "2026-09-01 00:00:00", end: "2026-12-31 00:00:00", total: "50", used: "50"),
        ]), now: now)
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(usage.secondary)
        XCTAssertNil(usage.tertiary)
        XCTAssertTrue(usage.extraWindows.isEmpty)
    }

    func testWorkBuddyTokenFormsAndEmptyUsage() throws {
        XCTAssertEqual(WorkBuddyUsageReader.accessToken(from: "  wb-jwt-value\n")?.token, "wb-jwt-value")
        let fromJSON = WorkBuddyUsageReader.accessToken(
            from: #"{"auth":{"accessToken":"wb-jwt-json"},"account":{"uid":"uid-9"}}"#)
        XCTAssertEqual(fromJSON?.token, "wb-jwt-json")
        XCTAssertEqual(fromJSON?.userID, "uid-9")
        XCTAssertNil(WorkBuddyUsageReader.accessToken(from: #"{"auth":{}}"#))
        XCTAssertNil(WorkBuddyUsageReader.accessToken(from: "two tokens pasted"))
        XCTAssertThrowsError(try WorkBuddyUsageReader.parse(
            Data(#"{"data":{"Response":{"Data":{"Accounts":[]}}}}"#.utf8)))
        XCTAssertThrowsError(try WorkBuddyUsageReader.parse(Data(#"{"code":14018}"#.utf8)))
    }
}
