import Foundation

/// DeepSeek balances. The API-key channel calls the official balance API; the
/// platform-token channel reads the web console's wallet summary. DeepSeek
/// publishes no usage percentage anywhere, so only money windows are emitted.
enum DeepSeekUsageReader {
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let summaryURL = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!

    private struct BalanceEnvelope: Decodable {
        let isAvailable: Bool?
        let balanceInfos: [BalanceInfo]?
        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String?
        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
        }
    }

    private struct SummaryEnvelope: Decodable {
        struct Data: Decodable {
            struct BizData: Decodable {
                struct Wallet: Decodable {
                    let balance: LossyNumber?
                    let currency: String?
                }
                let normalWallets: [Wallet]?
                let bonusWallets: [Wallet]?
                enum CodingKeys: String, CodingKey {
                    case normalWallets = "normal_wallets"
                    case bonusWallets = "bonus_wallets"
                }
            }
            let bizCode: Int?
            let bizData: BizData?
            enum CodingKeys: String, CodingKey {
                case bizCode = "biz_code"
                case bizData = "biz_data"
            }
        }
        let code: Int?
        let data: Data?
    }

    struct LossyNumber: Decodable {
        let value: Double?
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = nil
            }
        }
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        switch credential.kind {
        case .apiKey:
            let apiKey = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let data: Data
            do {
                data = try await NativeHTTP.request("GET", balanceURL, headers: [
                    "Authorization": "Bearer " + apiKey,
                ]).data
            } catch let failure as NativeHTTP.Failure {
                if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
                if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
                throw failure
            }
            return try parse(balanceData: data, summaryData: nil, seedMaterial: apiKey)
        case .cookie:
            let token = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 20, !token.contains(" ") else { throw NativeProviderAPIError.credentialRejected }
            let data: Data
            do {
                data = try await NativeHTTP.request("GET", summaryURL, headers: [
                    "Authorization": "Bearer " + token,
                ]).data
            } catch let failure as NativeHTTP.Failure {
                if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
                if case .httpStatus(403) = failure { throw NativeProviderAPIError.credentialRejected }
                throw failure
            }
            return try parse(balanceData: nil, summaryData: data, seedMaterial: token)
        default:
            throw NativeProviderAPIError.credentialRejected
        }
    }

    static func parse(balanceData: Data?, summaryData: Data?, seedMaterial: String) throws -> NativeUsage {
        var usage = NativeUsage(
            identitySeed: NativeAPIParsing.legacyCredentialSeed(provider: "deepseek", material: seedMaterial),
            updatedAt: Date())
        if let balanceData {
            let envelope = try NativeHTTP.decode(BalanceEnvelope.self, from: balanceData)
            guard let infos = envelope.balanceInfos, let info = Self.choose(info: infos) else {
                throw NativeProviderAPIError.parseFailure
            }
            guard let balance = info.totalBalance.flatMap({ Double($0) }), balance.isFinite, balance >= 0 else {
                throw NativeProviderAPIError.parseFailure
            }
            usage.cost = .init(used: 0, limit: 0,
                               balance: envelope.isAvailable == false ? 0 : balance,
                               currency: info.currency, period: "Balance")
        }
        if let summaryData {
            let envelope = try NativeHTTP.decode(SummaryEnvelope.self, from: summaryData)
            if envelope.code != 0 || envelope.data?.bizCode != 0 {
                if [40002, 40003].contains(envelope.data?.bizCode ?? 0) || envelope.code == 401 {
                    throw NativeProviderAPIError.credentialRejected
                }
                throw NativeProviderAPIError.parseFailure
            }
            guard let wallets = envelope.data?.bizData else { throw NativeProviderAPIError.parseFailure }
            let all = (wallets.normalWallets ?? []) + (wallets.bonusWallets ?? [])
            guard let currency = all.first?.currency,
                  all.allSatisfy({ wallet in guard let value = wallet.balance?.value else { return true }; return value.isFinite && value >= 0 }) else {
                throw NativeProviderAPIError.parseFailure
            }
            let balance = all.reduce(0.0, { $0 + ($1.balance?.value ?? 0) })
            usage.cost = .init(used: 0, limit: 0, balance: balance, currency: currency, period: "Balance")
        }
        guard usage.cost != nil else { throw NativeProviderAPIError.parseFailure }
        return usage
    }

    /// USD rows with balance win, then any row with balance, then USD, then the first.
    private static func choose(info infos: [BalanceInfo]) -> BalanceInfo? {
        infos.first { $0.currency == "USD" && (Double($0.totalBalance ?? "") ?? 0) > 0 }
            ?? infos.first { (Double($0.totalBalance ?? "") ?? 0) > 0 }
            ?? infos.first { $0.currency == "USD" }
            ?? infos.first
    }
}
