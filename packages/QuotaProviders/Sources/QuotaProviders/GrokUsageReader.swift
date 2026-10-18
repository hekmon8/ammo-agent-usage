import Foundation

/// Grok credits via the CLI billing proxy, the supported bearer-token channel
/// for a SuperGrok login. The grok.com gRPC-web endpoint requires a browser
/// key exchange and is intentionally not reimplemented.
enum GrokUsageReader {
    static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private struct BillingEnvelope: Decodable {
        struct Money: Decodable {
            let val: Double?
        }
        struct Period: Decodable {
            let start: String?
            let end: String?
        }
        struct Config: Decodable {
            let creditUsagePercent: Double?
            let currentPeriod: Period?
            let billingPeriodEnd: String?
            let onDemandCap: Money?
            let onDemandUsed: Money?
            let subscriptionTier: String?
        }
        let config: Config?
    }

    /// Accepts a SuperGrok bearer token. Management keys and pasted cookies
    /// are shaped differently and rejected instead of sent to the wrong API.
    static func normalizedToken(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !token.isEmpty, token.utf8.count <= 8_192,
              !token.lowercased().hasPrefix("cookie:"), !token.lowercased().hasPrefix("xai-"),
              !token.contains("=") else { return nil }
        return token
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey, let token = normalizedToken(credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        let data: Data
        do {
            let response = try await NativeHTTP.request("GET", endpoint, headers: [
                "Authorization": "Bearer " + token,
                "x-xai-token-auth": "xai-grok-cli",
                "User-Agent": "Ammo/1",
            ])
            data = response.data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
            throw failure
        }
        return try parse(data: data, identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "grok", material: token))
    }

    static func parse(data: Data, identitySeed: String? = nil,
                      identity: NativeUsage.Identity = .init()) throws -> NativeUsage {
        let envelope = try NativeHTTP.decode(BillingEnvelope.self, from: data)
        guard let config = envelope.config else { throw NativeProviderAPIError.parseFailure }
        let usedPercent: Double?
        if let published = config.creditUsagePercent {
            usedPercent = NativeAPIParsing.clampPercent(published)
        } else if let cap = config.onDemandCap?.val, cap > 0, let used = config.onDemandUsed?.val, used >= 0 {
            usedPercent = NativeAPIParsing.clampPercent(used / cap * 100)
        } else {
            usedPercent = nil
        }
        // The credits schema declares credit_usage_percent as a proto3
        // implicit-presence float and grok's own web client reads the omitted
        // scalar as zero, so a complete current period that contains now and
        // carries no percentage anywhere is a measured zero, not unknown usage.
        // Anything less complete stays unknown.
        let zeroUsage = usedPercent == nil
            ? Self.implicitZeroUsage(period: config.currentPeriod, now: Date()) : nil
        let resetsAt = NativeAPIParsing.date(config.currentPeriod?.end) ?? NativeAPIParsing.date(config.billingPeriodEnd)
        let duration: Int?
        if let start = NativeAPIParsing.date(config.currentPeriod?.start),
           let end = NativeAPIParsing.date(config.currentPeriod?.end), end > start {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            duration = minutes > 0 && minutes <= 527_040 ? minutes : nil
        } else {
            duration = nil
        }
        guard let usedPercent = usedPercent ?? zeroUsage, let resetsAt else {
            throw NativeProviderAPIError.parseFailure
        }
        return NativeUsage(
            primary: .init(id: "credits", usedPercent: usedPercent, windowMinutes: duration, resetsAt: resetsAt),
            identity: identity,
            identitySeed: identitySeed,
            updatedAt: Date())
    }

    private static func implicitZeroUsage(period: BillingEnvelope.Period?, now: Date) -> Double? {
        guard let start = NativeAPIParsing.date(period?.start),
              let end = NativeAPIParsing.date(period?.end),
              end > start, start <= now, now <= end else { return nil }
        return 0
    }
}
