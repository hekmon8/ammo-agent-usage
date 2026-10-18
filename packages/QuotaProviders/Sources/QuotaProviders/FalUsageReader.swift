import Foundation

/// Account billing is authoritative; model inference keys cannot read this API.
enum FalUsageReader {
    private struct Envelope: Decodable {
        struct Credits: Decodable { let current_balance: Double; let currency: String }
        let username: String
        let credits: Credits?
    }
    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey else { throw NativeProviderAPIError.credentialRejected }
        let response = try await NativeHTTP.request("GET", URL(string: "https://api.fal.ai/v1/account/billing?expand=credits")!,
            headers: ["Authorization": "Key " + credential.value.trimmingCharacters(in: .whitespacesAndNewlines)])
        return try parse(response.data)
    }
    static func parse(_ data: Data, now: Date = Date()) throws -> NativeUsage {
        let envelope = try NativeHTTP.decode(Envelope.self, from: data)
        guard !envelope.username.isEmpty, let credits = envelope.credits,
              credits.current_balance.isFinite, credits.current_balance >= 0,
              credits.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ProviderFailure.parseChanged
        }
        return NativeUsage(cost: .init(used: 0, limit: 0, balance: credits.current_balance,
            currency: credits.currency, period: "Prepaid credits"),
            identity: .init(accountID: envelope.username), updatedAt: now)
    }
}
