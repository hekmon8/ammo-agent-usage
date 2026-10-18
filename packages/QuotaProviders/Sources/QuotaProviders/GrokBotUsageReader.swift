import Foundation

/// Grok chat (grok.com bot) rate-limit windows via the web app's
/// `rest/rate-limits` endpoint, authenticated with the logged-in browser
/// session's `sso` cookie. Each model pool ("auto", "fast", "heavy") carries
/// its own rolling query allowance, so a cookie connection renders the bot's
/// time-limited quotas next to the CLI channel's billing credits. The
/// gRPC-web billing surface still requires a browser key exchange and is
/// intentionally not reimplemented here.
enum GrokBotUsageReader {
    static let endpoint = URL(string: "https://grok.com/rest/rate-limits")!

    /// Model pools the web client queries as `modelName`. A pool the account
    /// cannot use fails on its own response shape and is skipped; the tier is
    /// never assumed here.
    static let pools = ["auto", "fast", "expert", "heavy"]

    /// Placeholder the web bundle sends when its statsig worker cannot produce
    /// a signed id; grok.com accepts it in place of a signed one.
    private static let statsigFallback =
        "ZTpUeXBlRXJyb3I6IENhbm5vdCByZWFkIHByb3BlcnRpZXMgb2YgdW5kZWZpbmVkIChyZWFkaW5nICdjaGlsZE5vZGVzJyk="

    private struct RateLimitEnvelope: Decodable {
        let remainingQueries: Int?
        let totalQueries: Int?
        let windowSizeSeconds: Int?
        let waitTimeSeconds: Int?
    }

    /// A pasted cookie header is reduced to the `sso`/`sso-rw` session pairs
    /// plus `cf_clearance`; a bare session token is accepted as the `sso`
    /// value. Other pairs are dropped so the vault never stores more than the
    /// channel needs.
    static func sessionCookies(from raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cookie:") {
            trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        var sso: String?
        var ssoRW: String?
        var clearance: String?
        if trimmed.contains("=") {
            for pair in trimmed.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                if name == "sso" { sso = sso ?? value }
                else if name == "sso-rw" { ssoRW = ssoRW ?? value }
                else if name == "cf_clearance" { clearance = clearance ?? value }
            }
        } else if !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains(";"),
                  !trimmed.lowercased().hasPrefix("xai-") {
            // An API management key is shaped for a different channel and is
            // never silently converted into a session cookie.
            sso = trimmed
        }
        guard let primary = sso ?? ssoRW, primary.utf8.count <= 4_096 else { return nil }
        var pairs = ["sso=\(primary)", "sso-rw=\(ssoRW ?? primary)"]
        if let clearance { pairs.append("cf_clearance=\(clearance)") }
        return pairs.joined(separator: "; ")
    }

    static func requestHeaders(cookies: String, requestID: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Cookie": cookies,
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/",
            "x-statsig-id": statsigFallback,
            "x-xai-request-id": requestID,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
        ]
    }

    static func fetch(_ credential: NativeProviderCredential, now: Date = Date()) async throws -> NativeUsage {
        guard credential.kind == .cookie, let cookies = sessionCookies(from: credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        var windows: [NativeUsage.Window] = []
        var lastFailure: Error?
        for pool in pools {
            do {
                windows.append(try await fetchWindow(pool: pool, cookies: cookies, now: now))
            } catch let failure as NativeProviderAPIError {
                // A rejected session fails the whole fetch; an unusable single
                // pool (wrong tier, changed shape) only drops its own window.
                if case .credentialRejected = failure { throw failure }
                lastFailure = failure
            } catch {
                lastFailure = error
            }
        }
        guard let first = windows.first else { throw lastFailure ?? NativeProviderAPIError.parseFailure }
        return NativeUsage(
            extraWindows: windows,
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "grok", material: sessionValue(cookies: cookies)),
            updatedAt: now)
    }

    static func fetchWindow(pool: String, cookies: String, now: Date) async throws -> NativeUsage.Window {
        let body = try JSONSerialization.data(withJSONObject: ["modelName": pool])
        let data: Data
        do {
            data = try await NativeHTTP.request(
                "POST", endpoint,
                headers: requestHeaders(cookies: cookies, requestID: UUID().uuidString),
                body: body).data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        return try parse(data: data, pool: pool, now: now)
    }

    static func parse(data: Data, pool: String, now: Date = Date()) throws -> NativeUsage.Window {
        let envelope = try NativeHTTP.decode(RateLimitEnvelope.self, from: data)
        guard let remaining = envelope.remainingQueries, remaining >= 0,
              let total = envelope.totalQueries, total > 0 else {
            throw NativeProviderAPIError.parseFailure
        }
        let windowSeconds: Int
        if let published = envelope.windowSizeSeconds, published >= 60, published <= 30 * 24 * 3_600 {
            windowSeconds = published
        } else {
            // The endpoint observes the same two-hour default whenever the
            // scalar is omitted; anything past a month is a shape change.
            windowSeconds = 7_200
        }
        let usedPercent = NativeAPIParsing.clampPercent(Double(total - remaining) / Double(total) * 100)
        // A rolling window has no published anchor. waitTimeSeconds is the
        // server's own "when a query frees up"; otherwise the observation time
        // anchors the estimate and every refresh replaces it.
        let resetSeconds = (envelope.waitTimeSeconds.flatMap { $0 > 0 ? $0 : nil }) ?? windowSeconds
        return NativeUsage.Window(
            id: "bot-\(pool)",
            usedPercent: usedPercent,
            windowMinutes: windowSeconds / 60,
            resetsAt: now.addingTimeInterval(TimeInterval(resetSeconds)))
    }

    private static func sessionValue(cookies: String) -> String {
        for pair in cookies.split(separator: "; ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "sso" { return String(parts[1]) }
        }
        return cookies
    }
}
