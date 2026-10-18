import Foundation

/// Amp balance via the signed-in API. The endpoint answers with a display
/// text blob that carries every balance line; each line is matched against a
/// narrow pattern and anything unrecognized is ignored rather than guessed.
enum AmpUsageReader {
    private static let endpoint = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!

    private struct Envelope: Decodable {
        struct APIError: Decodable {
            let code: String?
            let message: String?
        }
        struct Result: Decodable {
            let displayText: String?
        }
        let ok: Bool?
        let result: Result?
        let error: APIError?
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey else { throw NativeProviderAPIError.credentialRejected }
        let body = try JSONSerialization.data(
            withJSONObject: ["method": "userDisplayBalanceInfo", "params": [String: String]()])
        let response: NativeHTTP.Response
        do {
            response = try await NativeHTTP.request("POST", endpoint, headers: [
                "Authorization": "Bearer " + credential.value,
                "Content-Type": "application/json",
            ], body: body)
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        let envelope = try NativeHTTP.decode(Envelope.self, from: response.data)
        if envelope.ok == false, envelope.error?.code == "auth-required" {
            throw NativeProviderAPIError.credentialRejected
        }
        guard let text = envelope.result?.displayText, !text.isEmpty else {
            throw NativeProviderAPIError.parseFailure
        }
        return try parse(text, now: Date())
    }

    static func parse(_ raw: String, now: Date = Date()) throws -> NativeUsage {
        var text = raw.replacingOccurrences(of: "**", with: "")
        if let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") {
            text = ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if text.range(of: "sign in|log in|login", options: .regularExpression) != nil {
            throw NativeProviderAPIError.authenticationRequired
        }
        var email: String?
        var organization: String?
        if let capture = NativeAPIParsing.firstMatch(text, "^\\s*Signed in as\\s+([^\\s(]+)(?:\\s+\\(([^\\r\\n)]+)\\))?\\s*$") {
            email = capture[0]
            organization = capture[1]
        }
        var usage = NativeUsage(identity: .init(email: email, organization: organization), updatedAt: now)

        if let capture = NativeAPIParsing.firstMatch(text, "Amp Free:\\s*\\$([0-9,.]+)\\s*/\\s*\\$([0-9,.]+)\\s+remaining(?:\\s*\\(replenishes\\s*\\+\\$([0-9,.]+)/hour\\))?") {
            let remaining = NativeAPIParsing.money(capture[0]) ?? 0
            let quota = NativeAPIParsing.money(capture[1]) ?? 0
            let hourly = capture[2].flatMap { NativeAPIParsing.money($0) } ?? 0
            if quota > 0 {
                let used = min(quota, max(0, quota - remaining))
                let usedPercent = NativeAPIParsing.clampPercent(used / quota * 100)
                var minutes: Int?
                var resetsAt: Date?
                if hourly > 0 {
                    minutes = max(60, Int((quota / hourly).rounded()) * 60)
                    resetsAt = now.addingTimeInterval(used / hourly * 3600)
                }
                usage.extraWindows.append(.init(id: "amp-free", usedPercent: usedPercent,
                                                windowMinutes: minutes, resetsAt: resetsAt))
            }
        } else if let capture = NativeAPIParsing.firstMatch(text, "Amp Free:\\s*([0-9.]+)%\\s+remaining(?:\\s+today)?(?:\\s*\\(resets daily\\))?") {
            let remainingPercent = Double(capture[0] ?? "0") ?? 0
            let usedPercent = NativeAPIParsing.clampPercent(100 - remainingPercent)
            usage.extraWindows.append(.init(id: "amp-free", usedPercent: usedPercent,
                                            windowMinutes: 24 * 60,
                                            resetsAt: NativeAPIParsing.nextEasternTwentyOClock(from: now)))
        }

        if let capture = NativeAPIParsing.firstMatch(text, "(?:Amp\\s+)?Subscription\\s+[^:]*:\\s*([0-9.]+)%\\s+other usage and\\s+([0-9.]+)%\\s+orb usage\\s+remaining\\s*-\\s*resets upon renewal in\\s+([0-9]+)\\s+(days|months)") {
            let otherRemaining = Double(capture[0] ?? "0") ?? 0
            let orbRemaining = Double(capture[1] ?? "0") ?? 0
            let count = Int(capture[2] ?? "0") ?? 0
            let resetsAt = capture[3] == "months"
                ? NativeAPIParsing.monthsFromNow(count, from: now)
                : now.addingTimeInterval(TimeInterval(count) * 86_400)
            usage.primary = .init(id: "subscription-other",
                                  usedPercent: NativeAPIParsing.clampPercent(100 - otherRemaining),
                                  windowMinutes: 43_200, resetsAt: resetsAt)
            usage.secondary = .init(id: "subscription-orb",
                                    usedPercent: NativeAPIParsing.clampPercent(100 - orbRemaining),
                                    windowMinutes: 43_200, resetsAt: resetsAt)
        }

        var balance: Double?
        var freeBalance: Double?
        var freeResetsAt: Date?
        // The headline number folds the daily free allowance in; the
        // parenthetical names its share, so split purchased from free.
        if let capture = NativeAPIParsing.firstMatch(text, "Individual credits:\\s*\\$([0-9,.]+)\\s+remaining(?:\\s*\\(includes\\s*\\$([0-9,.]+)\\s+Amp Free remaining today[^)]*\\))?") {
            let total = NativeAPIParsing.money(capture[0]) ?? 0
            let free = capture[1].flatMap { NativeAPIParsing.money($0) } ?? 0
            if free > 0 {
                freeBalance = free
                freeResetsAt = NativeAPIParsing.nextEasternTwentyOClock(from: now)
                balance = max(0, total - free)
            } else {
                balance = total
            }
        }
        if balance == nil {
            var workspaces = 0.0
            for capture in NativeAPIParsing.allMatches(text, "Workspace\\s+[^:]*:\\s*\\$([0-9,.]+)\\s+remaining") {
                workspaces += NativeAPIParsing.money(capture[0]) ?? 0
            }
            if workspaces > 0 { balance = workspaces }
        }
        if let balance {
            // Prepaid store credit: exposed as a balance only, never as spend.
            usage.cost = .init(used: 0, limit: 0, balance: balance,
                               currency: "USD", period: "Prepaid credits",
                               freeBalance: freeBalance, freeResetsAt: freeResetsAt)
        }
        if usage.primary == nil, usage.secondary == nil, usage.extraWindows.isEmpty, usage.cost == nil {
            throw NativeProviderAPIError.parseFailure
        }
        return usage
    }
}

extension NativeAPIParsing {
    /// First regex match's capture groups (nil-padded), with case-insensitive
    /// and multiline semantics so display text lines match naturally.
    static func firstMatch(_ text: String, _ pattern: String) -> [String?]? {
        allMatches(text, pattern).first
    }

    static func allMatches(_ text: String, _ pattern: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<max(match.numberOfRanges, 1)).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}
