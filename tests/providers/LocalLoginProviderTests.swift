@testable import QuotaProviders
import XCTest

/// Coverage for the on-device CLI-login channels. The identity digests are
/// part of the released connection format; the golden values here pin the
/// exact input strings.
final class LocalLoginProviderTests: XCTestCase {
    // MARK: - Codex ambient login

    private func jwt(sub: String, exp: Double? = nil) -> String {
        var claims: [String: Any] = ["sub": sub]
        if let exp { claims["exp"] = exp }
        let payload = String(decoding: try! JSONSerialization.data(withJSONObject: claims), as: UTF8.self)
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "aaa.\(encoded).bbb"
    }

    private func codexAuthJSON(accessSub: String, accessExp: Double, accountID: String, includeIDToken: Bool = true) -> Data {
        var tokens: [String: Any] = [
            "access_token": jwt(sub: accessSub, exp: accessExp),
            "refresh_token": "refresh-value",
            "account_id": accountID,
        ]
        if includeIDToken { tokens["id_token"] = jwt(sub: "id-\(accessSub)", exp: accessExp) }
        return try! JSONSerialization.data(withJSONObject: ["tokens": tokens, "last_refresh": "2026-09-01T00:00:00Z"])
    }

    func testCodexCredentialParsingAcceptsTokensAndRejectsAPIKeyFiles() throws {
        let farFuture = Date().timeIntervalSince1970 + 86_400
        let credentials = try CodexLocalProvider.readCredentials(
            from: codexAuthJSON(accessSub: "subject-1", accessExp: farFuture, accountID: "acct-1"))
        XCTAssertEqual(credentials.accountID, "acct-1")
        XCTAssertFalse(credentials.needsRefresh)
        XCTAssertThrowsError(try CodexLocalProvider.readCredentials(
            from: Data(#"{"OPENAI_API_KEY":"sk-nope"}"#.utf8)))
        // The CLI persists a null key slot alongside valid tokens.
        let nullKeyJSON = """
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"access_token":"\(jwt(sub: "subject-1", exp: farFuture))","refresh_token":"r","account_id":"acct-1"},"last_refresh":"2026-09-01T00:00:00Z"}
        """
        let nullKey = try CodexLocalProvider.readCredentials(from: Data(nullKeyJSON.utf8))
        XCTAssertEqual(nullKey.accountID, "acct-1")
        XCTAssertThrowsError(try CodexLocalProvider.readCredentials(
            from: codexAuthJSON(accessSub: "subject-1", accessExp: 1_000, accountID: "acct-1"),
            now: Date(timeIntervalSince1970: 2_000)))
    }

    func testCodexIdentityDigestIsStable() throws {
        let farFuture = Date().timeIntervalSince1970 + 86_400
        let credentials = try CodexLocalProvider.readCredentials(
            from: codexAuthJSON(accessSub: "subject-1", accessExp: farFuture, accountID: "acct-1"))
        let fingerprint = try XCTUnwrap(credentials.identityFingerprint)
        XCTAssertEqual(fingerprint, NativeProviderNormalizer.sha256("codex-local-login\nacct-1\nsubject-1"))
        XCTAssertEqual("account-" + String(fingerprint.prefix(16)), "account-" + String(fingerprint.prefix(16)))
    }

    func testCodexNormalizeMapsWindowsCreditsSparkAndAccountGuard() throws {
        let usage = Data("""
        {"rate_limit":{"primary_window":{"used_percent":30,"reset_at":1790000000,"limit_window_seconds":18000},
                       "secondary_window":{"used_percent":10,"reset_at":1790000000,"limit_window_seconds":604800}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"4.5"},
         "additional_rate_limits":[{"metered_feature":"GPT-5.3 Codex Spark",
            "rate_limit":{"primary_window":{"used_percent":55,"reset_at":1790000000,"limit_window_seconds":86400}}}]}
        """.utf8)
        let accountID = "account-abcdef1234567890"
        let windows = try CodexLocalProvider.normalize(
            usageData: usage, resetsData: nil, remoteAccountID: "acct-1",
            accountID: accountID, alias: "Codex", now: Date())
        XCTAssertTrue(windows.contains { $0.quotaKey == "codex-primary" && $0.remainingBps == 7000 })
        XCTAssertTrue(windows.contains { $0.quotaKey == "codex-secondary" && $0.remainingBps == 9000 })
        XCTAssertTrue(windows.contains { $0.quotaKey == "credit-balance" && $0.amount == "4.5" })
        XCTAssertTrue(windows.contains { $0.quotaKey == "spark-primary" && $0.remainingBps == 4500 })
        // A response naming a different account must stop the connection.
        let other = Data("""
        {"account_id":"acct-2","rate_limit":{"primary_window":{"used_percent":1,"reset_at":1,"limit_window_seconds":60}}}
        """.utf8)
        XCTAssertThrowsError(try CodexLocalProvider.normalize(
            usageData: other, resetsData: nil, remoteAccountID: "acct-1",
            accountID: accountID, alias: "Codex", now: Date()))
    }

    // MARK: - Grok ambient login

    private func grokAuthJSON(userID: String, teamID: String?, expiresAt: String? = nil,
                              key: String = "oidc-token-value") -> Data {
        var entry: [String: Any] = [
            "key": key, "user_id": userID, "email": "me@example.com",
            "principal_type": "User",
        ]
        if let teamID { entry["team_id"] = teamID }
        if let expiresAt { entry["expires_at"] = expiresAt }
        return try! JSONSerialization.data(withJSONObject: ["https://auth.x.ai::oidc": entry])
    }

    func testGrokEntryParsingPrefersOIDCScope() throws {
        let entry = try GrokLocalProvider.readEntry(from: grokAuthJSON(userID: "user-1", teamID: "team-1"))
        XCTAssertEqual(entry.userID, "user-1")
        XCTAssertEqual(entry.teamID, "team-1")
        XCTAssertThrowsError(try GrokLocalProvider.readEntry(
            from: Data(#"{"https://other::x":{"key":"k","user_id":"u"}}"#.utf8)))
    }

    func testGrokEntryParsingCarriesExpiry() throws {
        let raw = "2026-09-17T05:07:46.633396Z"
        let entry = try GrokLocalProvider.readEntry(from: grokAuthJSON(userID: "user-1", teamID: nil, expiresAt: raw))
        XCTAssertEqual(entry.expiresAt, NativeAPIParsing.date(raw))
        let legacy = try GrokLocalProvider.readEntry(from: grokAuthJSON(userID: "user-1", teamID: nil))
        XCTAssertNil(legacy.expiresAt)
    }

    func testGrokExpiryDecisionPrefersExpiresAtThenJWTClaim() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        func entry(expiresAt: Date?, exp: Double?) -> GrokLocalProvider.AuthEntry {
            let key = exp.map { self.jwt(sub: "user-1", exp: $0) } ?? "oidc-token-value"
            return GrokLocalProvider.AuthEntry(
                token: key, userID: "user-1", teamID: nil, email: nil, expiresAt: expiresAt)
        }
        // The file's own deadline wins when present.
        XCTAssertTrue(GrokLocalProvider.isExpired(entry(expiresAt: now.addingTimeInterval(-10), exp: nil), now: now))
        XCTAssertFalse(GrokLocalProvider.isExpired(entry(expiresAt: now.addingTimeInterval(3_600), exp: nil), now: now))
        // 30-second skew margin.
        XCTAssertTrue(GrokLocalProvider.isExpired(entry(expiresAt: now.addingTimeInterval(20), exp: nil), now: now))
        XCTAssertFalse(GrokLocalProvider.isExpired(entry(expiresAt: now.addingTimeInterval(40), exp: nil), now: now))
        // Without `expires_at`, the token's exp claim decides.
        XCTAssertTrue(GrokLocalProvider.isExpired(entry(expiresAt: nil, exp: now.timeIntervalSince1970 - 10), now: now))
        XCTAssertFalse(GrokLocalProvider.isExpired(entry(expiresAt: nil, exp: now.timeIntervalSince1970 + 3_600), now: now))
        // No deadline anywhere stays sendable (the proxy still rejects it).
        XCTAssertFalse(GrokLocalProvider.isExpired(entry(expiresAt: nil, exp: nil), now: now))
    }

    func testGrokRefreshBinaryCandidatesAndVerification() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let authFile = temp.appendingPathComponent("auth.json")
        let candidates = GrokNativeRefresh.candidateBinaries(authFile: authFile)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(candidates.first, temp.appendingPathComponent("bin/grok"))
        // A user-owned executable at a candidate path verifies; the same file
        // without its executable bit, a directory, and a missing path do not.
        let binary = temp.appendingPathComponent("bin/grok")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertNotNil(GrokNativeRefresh.verifiedBinary(at: binary))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        XCTAssertNil(GrokNativeRefresh.verifiedBinary(at: binary))
        XCTAssertNil(GrokNativeRefresh.verifiedBinary(at: temp.appendingPathComponent("bin")))
        XCTAssertNil(GrokNativeRefresh.verifiedBinary(at: temp.appendingPathComponent("bin/missing")))
    }

    func testGrokRefreshLaunchWaitsForExitAndTimesOutKillingChild() async throws {
        try await GrokNativeRefresh.run(binary: URL(fileURLWithPath: "/bin/echo"), arguments: ["done"], timeout: 10)
        do {
            try await GrokNativeRefresh.run(binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 1)
            XCTFail("expected the bounded launch to time out")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure, .timeout)
        }
    }

    func testGrokIdentityDigestMatchesReleasedTeamScopedForm() {
        XCTAssertEqual(
            GrokLocalProvider.fingerprint(userID: "user-1", teamID: "team-1"),
            NativeProviderNormalizer.sha256("automatic-account-id\ngrok\nuser-1\norganization=team-1"))
        XCTAssertEqual(
            GrokLocalProvider.fingerprint(userID: "solo", teamID: nil),
            NativeProviderNormalizer.sha256("automatic-account-id\ngrok\nsolo"))
    }

    func testGrokFetchProducesReleasedAccountIDShape() throws {
        let data = Data(#"{"config":{"creditUsagePercent":37.5,"currentPeriod":{"end":"2026-09-30T00:00:00Z"}}}"#.utf8)
        let usage = try GrokUsageReader.parse(
            data: data, identity: .init(accountID: "user-1", email: "me@example.com", organization: "team-1"))
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "grok", alias: "Grok", source: .officialAPI)
        let fingerprint = GrokLocalProvider.fingerprint(userID: "user-1", teamID: "team-1")
        XCTAssertEqual(result.accountID, "native-" + String(fingerprint.prefix(32)))
        XCTAssertEqual(result.identityFingerprint, fingerprint)
    }

    func testGrokOmittedPercentInsideCompleteActivePeriodIsMeasuredZero() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let start = formatter.string(from: now.addingTimeInterval(-86_400))
        let end = formatter.string(from: now.addingTimeInterval(6 * 86_400))
        let data = Data("""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},
                   "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}}}
        """.utf8)
        let usage = try GrokUsageReader.parse(data: data)
        let primary = try XCTUnwrap(usage.primary)
        XCTAssertEqual(primary.usedPercent, 0)
        XCTAssertEqual(primary.windowMinutes, 7 * 24 * 60)
        XCTAssertEqual(primary.resetsAt, formatter.date(from: end))
        // Without the complete period the same payload stays unknown usage.
        let periodOnly = Data("""
        {"config":{"currentPeriod":{"end":"\(end)"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}
        """.utf8)
        XCTAssertThrowsError(try GrokUsageReader.parse(data: periodOnly))
    }

    func testClaudeStoredCredentialsTokenAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func stored(expiresAt: Double?) -> Data {
            var oauth: [String: Any] = ["accessToken": "sk-ant-oat01-abc", "refreshToken": "r", "scopes": ["user:profile"]]
            if let expiresAt { oauth["expiresAt"] = expiresAt }
            return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        }
        XCTAssertEqual(try ClaudeLocalProvider.accessToken(from: stored(expiresAt: (now.timeIntervalSince1970 + 3_600) * 1000), now: now), "sk-ant-oat01-abc")
        XCTAssertEqual(try ClaudeLocalProvider.accessToken(from: stored(expiresAt: nil), now: now), "sk-ant-oat01-abc")
        XCTAssertThrowsError(try ClaudeLocalProvider.accessToken(from: stored(expiresAt: (now.timeIntervalSince1970 + 10) * 1000), now: now))
        XCTAssertThrowsError(try ClaudeLocalProvider.accessToken(from: Data(#"{"mcpOAuth":{}}"#.utf8), now: now))
    }

    func testClaudeLocalRecordValidation() throws {
        let record = ProviderConnectionRecord(id: "local-claude-x", kind: .claudeLocalLogin, providerID: "claude",
                                              accountID: "native-1", accountAlias: "Claude", expectedIdentity: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try record.validated())
        XCTAssertTrue(ProviderConnectionKind.claudeLocalLogin.usesLocalLogin)
        let wrong = ProviderConnectionRecord(id: "local-claude-y", kind: .claudeLocalLogin, providerID: "grok",
                                             accountID: "native-1", accountAlias: "Claude", expectedIdentity: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try wrong.validated())
    }

    // MARK: - WorkBuddy ambient login

    private func workbuddySessionFile(expiresAt: Double?, uid: String? = "uid-1") -> Data {
        var auth: [String: Any] = ["accessToken": "wb-jwt-file-value"]
        if let expiresAt { auth["expiresAt"] = expiresAt }
        var file: [String: Any] = ["auth": auth]
        if let uid { file["account"] = ["uid": uid] }
        return try! JSONSerialization.data(withJSONObject: file)
    }

    func testWorkBuddyStoredSessionTokenAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(try WorkBuddyLocalProvider.readSession(
            from: workbuddySessionFile(expiresAt: (now.timeIntervalSince1970 + 3_600) * 1000), now: now).accessToken, "wb-jwt-file-value")
        XCTAssertEqual(try WorkBuddyLocalProvider.readSession(
            from: workbuddySessionFile(expiresAt: nil), now: now).userID, "uid-1")
        XCTAssertThrowsError(try WorkBuddyLocalProvider.readSession(
            from: workbuddySessionFile(expiresAt: (now.timeIntervalSince1970 + 10) * 1000), now: now))
        XCTAssertThrowsError(try WorkBuddyLocalProvider.readSession(from: Data(#"{"account":{"uid":"u"}}"#.utf8), now: now))
    }

    func testWorkBuddyLocalRecordValidation() throws {
        let record = ProviderConnectionRecord(id: "local-workbuddy-x", kind: .workbuddyLocalLogin, providerID: "workbuddy",
                                              accountID: "native-1", accountAlias: "WorkBuddy", expectedIdentity: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try record.validated())
        XCTAssertTrue(ProviderConnectionKind.workbuddyLocalLogin.usesLocalLogin)
        let wrong = ProviderConnectionRecord(id: "local-workbuddy-y", kind: .workbuddyLocalLogin, providerID: "claude",
                                             accountID: "native-1", accountAlias: "WorkBuddy", expectedIdentity: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try wrong.validated())
    }

    func testZCodeLoginPinsAccountAndStaysSeparateFromAPIKey() throws {
        let claims = Data(#"{"user_id":"zcode-user-1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let store: [String: String] = [
            "oauth:active_provider": "bigmodel",
            "oauth:bigmodel:access_token": "coding-plan-token",
            "oauth:bigmodel:user_info": #"{"id":"zcode-user-1"}"#,
            "zcodejwttoken": "a.\(claims).b",
        ]
        let login = try XCTUnwrap(ZCodeCredentialReader.tokens(from: JSONEncoder().encode(store), secret: "test"))
        XCTAssertEqual(login.accountID, "zcode-user-1")
        XCTAssertEqual(login.region, "bigmodel")
        let identity = ZCodeLocalProvider.fingerprint(login)
        let record = ProviderConnectionRecord(id: "local-zcode-" + String(identity.prefix(24)),
            kind: .zcodeLocalLogin, providerID: "zcode", accountID: "native-" + String(identity.prefix(32)),
            accountAlias: "ZCode", expectedIdentity: identity)
        XCTAssertNoThrow(try record.validated())
        XCTAssertFalse(NativeProviderCatalog.apiProviderIDs.contains("zcode"))
        var switched = store
        switched["oauth:bigmodel:user_info"] = #"{"id":"other-user"}"#
        XCTAssertNil(ZCodeCredentialReader.tokens(from: try JSONEncoder().encode(switched), secret: "test"))
    }

    func testZCodeResetInventoryCountsOnlyUnexpiredCards() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = (now.timeIntervalSince1970 + 3600) * 1000
        let past = (now.timeIntervalSince1970 - 3600) * 1000
        let data = Data(#"{"code":0,"data":{"available_five_hour_resets":[{"expire_at":\#(future)},{"expire_at":\#(past)}],"available_week_resets":[]}}"#.utf8)
        let windows = try ZCodeLocalProvider.parse(data, accountID: "native-test", alias: "ZCode", now: now)
        XCTAssertEqual(windows.map(\.amount), ["1", "0"])
        XCTAssertEqual(windows.map(\.providerId), ["zcode", "zcode"])
        XCTAssertNotNil(windows[0].window.resetsAt)
        XCTAssertNil(windows[1].window.resetsAt)
        XCTAssertThrowsError(try ZCodeLocalProvider.parse(Data(#"{"code":0,"data":{}}"#.utf8),
                                                           accountID: "native-test", alias: "ZCode", now: now))
    }

    func testZCodeTransportFailuresKeepCollectorBackoffSemantics() {
        XCTAssertEqual(ZCodeLocalProvider.classify(.httpStatus(401)), .authRequired)
        XCTAssertEqual(ZCodeLocalProvider.classify(.httpStatus(403)), .authRequired)
        XCTAssertEqual(ZCodeLocalProvider.classify(.httpStatus(429)), .rateLimited(seconds: 300))
        XCTAssertEqual(ZCodeLocalProvider.classify(.transport(URLError(.timedOut))), .timeout)
    }
}
