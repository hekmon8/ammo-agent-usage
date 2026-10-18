import Foundation
import QuotaCore

/// Reset-card inventory owned by the active ZCode desktop login. Its account
/// identity is pinned independently of any z.ai API-key connection.
public struct ZCodeLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "zcode", displayName: "ZCode", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        credentialIdentity = expectedIdentity
    }

    private struct Envelope: Decodable {
        struct Card: Decodable { let expire_at: Double? }
        struct Inventory: Decodable {
            let available_five_hour_resets: [Card]?
            let available_week_resets: [Card]?
        }
        let code: Int?
        let data: Inventory?
    }

    static func fingerprint(_ login: ZCodeCredentialReader.Tokens) -> String {
        NativeProviderNormalizer.sha256("zcode-local-login\n\(login.region)\n\(login.accountID)")
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil)
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    private static func read(alias: String, expectedIdentity: String?) async throws -> NativeProviderProbeResult {
        try Task.checkCancellation()
        guard let login = ZCodeCredentialReader.login() else { throw ProviderFailure.authRequired }
        let identity = fingerprint(login)
        guard expectedIdentity == nil || identity == expectedIdentity else { throw ProviderFailure.authRequired }
        let headers = [
            "Authorization": "Bearer " + login.zcodeJWT,
            "X-Bigmodel-Authorization": login.codingPlanToken,
            "Bigmodel-Target-Type": "PERSONAL",
        ]
        let url = URL(string: "https://zcode.z.ai/api/v1/coding-plan/reset/status")!
        let data: Data
        do { data = try await NativeHTTP.request("GET", url, headers: headers).data }
        catch let failure as NativeHTTP.Failure {
            throw classify(failure)
        }
        let accountID = "native-" + String(identity.prefix(32))
        let windows = try parse(data, accountID: accountID, alias: alias, now: Date())
        return NativeProviderProbeResult(accountID: accountID, identityFingerprint: identity, windows: windows)
    }

    static func classify(_ failure: NativeHTTP.Failure) -> ProviderFailure {
        if case .httpStatus(403) = failure { return .authRequired }
        return NativeHTTP.classify(failure)
    }

    static func parse(_ data: Data, accountID: String, alias: String, now: Date) throws -> [QuotaWindow] {
        guard data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code == 0, let inventory = envelope.data,
              inventory.available_five_hour_resets != nil || inventory.available_week_resets != nil
        else { throw ProviderFailure.parseChanged }
        var windows: [QuotaWindow] = []
        for (key, cards) in [
            ("rate-limit-reset-credits", inventory.available_five_hour_resets),
            ("rate-limit-reset-credits-week", inventory.available_week_resets),
        ] {
            guard let cards else { continue }
            let expirations = cards.compactMap(\.expire_at)
                .filter { $0.isFinite && $0 > 0 }
                .map { Date(timeIntervalSince1970: $0 / 1000) }
                .filter { $0 > now }
            windows.append(.providerValue(
                id: "zcode-\(accountID)-\(key)", providerID: "zcode", accountID: accountID,
                alias: alias, key: key, unit: .requests, currency: nil,
                remainingBps: nil, amount: String(expirations.count), limit: nil,
                quality: .reported, source: .officialAPI, observedAt: now,
                staleAt: now.addingTimeInterval(600), windowKind: .unknown,
                duration: nil, resetsAt: expirations.min()))
        }
        return windows
    }
}
