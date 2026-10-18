import Foundation

/// WorkBuddy (Tencent's CodeBuddy desktop agent) subscription credits via the
/// billing endpoint the app's own plan screen reads. The credential is the
/// Bearer access token of WorkBuddy's desktop login, either pasted or re-read
/// from WorkBuddy's session file; it is never refreshed here, so an expired
/// token waits for the app's next renewal and then a reconnect. Every resource
/// package (plan, bonus, activity packs) becomes one percent window over its
/// own capacity cycle, and the response's shared Uin pins the account identity.
enum WorkBuddyUsageReader {
    static let endpoint = URL(string: "https://www.codebuddy.cn/billing/meter/get-user-resource")!
    /// The SaaS product code the desktop app queries; enterprise deployments use others.
    private static let productCode = "p_tcaca"

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Response: Decodable {
                struct Body: Decodable {
                    struct Account: Decodable {
                        let PackageCode: String?
                        let ResourceId: String?
                        let Uin: String?
                        let Status: Int?
                        let CycleCapacitySizePrecise: String?
                        let CycleCapacityUsedPrecise: String?
                        let CycleCapacityRemainPrecise: String?
                        let CapacitySizePrecise: String?
                        let CapacityUsedPrecise: String?
                        let CapacityRemainPrecise: String?
                        let CycleStartTime: WorkBuddyLocalTimestamp?
                        let CycleEndTime: WorkBuddyLocalTimestamp?
                        let DeductionEndTime: NativeFlexibleDate?
                    }
                    let Accounts: [Account]?
                }
                let Data: Body?
            }
            let Response: Response?
        }
        let data: Payload?
    }

    /// Accepts the bare access token or WorkBuddy's session JSON (the
    /// `workbuddy-desktop.info` file content, `{"auth":{"accessToken":…}}`).
    static func accessToken(from raw: String) -> (token: String, userID: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard let stored = try? JSONDecoder().decode(StoredSession.self, from: Data(trimmed.utf8)),
                  let token = stored.auth?.accessToken, token.count >= 8 else { return nil }
            return (token, stored.account?.uid)
        }
        guard trimmed.count >= 8, trimmed.utf8.count <= 8_192, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return (trimmed, nil)
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        guard credential.kind == .apiKey, let entry = accessToken(from: credential.value) else {
            throw NativeProviderAPIError.credentialRejected
        }
        return try await fetch(token: entry.token, userID: entry.userID)
    }

    static func fetch(token: String, userID: String?) async throws -> NativeUsage {
        var headers = [
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        ]
        if let userID { headers["X-User-Id"] = userID }
        let body = try JSONEncoder().encode(RequestBody())
        let data: Data
        do {
            data = try await NativeHTTP.request("POST", endpoint, headers: headers, body: body).data
        } catch {
            if case NativeHTTP.Failure.httpStatus(401) = error { throw NativeProviderAPIError.credentialRejected }
            if case NativeHTTP.Failure.httpStatus(403) = error { throw NativeProviderAPIError.credentialRejected }
            throw error
        }
        return try parse(data)
    }

    struct RequestBody: Encodable {
        let PageNumber = 1
        let PageSize = 100
        let ProductCode = WorkBuddyUsageReader.productCode
        /// valid + usedUp: exhausted packs still report their cycle for context.
        let Status = [0, 3]
        let PackageStartTimeRangeBegin = "2024-12-01 21:25:00"
        let PackageStartTimeRangeEnd = WorkBuddyClock.nowText()
    }

    private struct StoredSession: Decodable {
        struct Auth: Decodable { let accessToken: String? }
        struct Account: Decodable { let uid: String? }
        let auth: Auth?
        let account: Account?
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> NativeUsage {
        let envelope = try NativeHTTP.decode(Envelope.self, from: data)
        let accounts = envelope.data?.Response?.Data?.Accounts ?? []
        let packages: [Package] = accounts.compactMap { account -> Package? in
            guard [0, 3].contains(account.Status ?? -1) else { return nil }
            return Package(account: account, now: now)
        }.sorted { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.expiresAt < rhs.expiresAt
        }
        guard !packages.isEmpty else { throw ProviderFailure.unsupported }

        var usage = NativeUsage(updatedAt: now)
        if packages.count > 0 { usage.primary = packages[0].window(id: "primary") }
        if packages.count > 1 { usage.secondary = packages[1].window(id: "secondary") }
        if packages.count > 2 { usage.tertiary = packages[2].window(id: "tertiary") }
        usage.extraWindows = packages.dropFirst(3).enumerated().compactMap { offset, package in
            package.window(id: package.extraKey(fallbackIndex: offset))
        }
        usage.identity = .init(accountID: packages.compactMap { $0.uin }.first)
        return usage
    }

    /// One billed resource package: a credits pool with its own capacity cycle.
    private struct Package {
        let id: String
        let packageCode: String
        let uin: String?
        let usedPercent: Double
        let startsAt: Date?
        let resetsAt: Date?
        let expiresAt: Date
        let priority: Int

        init?(account: Envelope.Payload.Response.Body.Account, now: Date) {
            let total = NativeAPIParsing.money(account.CycleCapacitySizePrecise)
                ?? NativeAPIParsing.money(account.CapacitySizePrecise) ?? 0
            let used: Double
            if let reported = NativeAPIParsing.money(account.CycleCapacityUsedPrecise)
                ?? NativeAPIParsing.money(account.CapacityUsedPrecise) {
                used = reported
            } else if let remain = NativeAPIParsing.money(account.CycleCapacityRemainPrecise)
                ?? NativeAPIParsing.money(account.CapacityRemainPrecise) {
                used = max(0, total - remain)
            } else {
                used = 0
            }
            guard total > 0, used >= 0, let expiresAt = account.CycleEndTime?.value
                ?? account.DeductionEndTime?.value, expiresAt > now - 86_400 else { return nil }
            let code = account.PackageCode ?? ""
            guard !code.isEmpty else { return nil }
            id = account.ResourceId ?? ""
            packageCode = code
            uin = account.Uin
            usedPercent = NativeAPIParsing.clampPercent(used / total * 100)
            startsAt = account.CycleStartTime?.value
            resetsAt = account.CycleEndTime?.value ?? account.DeductionEndTime?.value
            self.expiresAt = expiresAt
            priority = Self.planPriority(code)
        }

        /// The desktop app's ranking: the purchased plan leads, granted packs
        /// and activity credits follow, the daily free allowance trails.
        static func planPriority(_ code: String) -> Int {
            switch code {
            case "TCACA_code_003_FAnt7lcmRT", "TCACA_code_002_AkiJS3ZHF5", "TCACA_code_005_maRGyrHhw1",
                 "TCACA_code_008_cfWoLwvjU4", "TCACA_code_023_4xbGhMrE6q", "TCACA_code_026_BaESVICNoi",
                 "TCACA_code_027_0FCGVA6vSa":
                return 1
            case "TCACA_code_028_NtpWi0jzXs": return 2
            case "TCACA_code_009_0XmEQc2xOf", "TCACA_code_038_OhvqZtiPKr": return 3
            case "TCACA_code_007_nzdH5h4Nl0", "TCACA_code_029_6wCGEWquYy", "TCACA_code_030_BjSt89qTvr": return 4
            case "TCACA_code_006_DbXS0lrypC": return 5
            case "TCACA_code_001_PqouKr6QWV": return 6
            default: return 7
            }
        }

        func window(id: String) -> NativeUsage.Window {
            var minutes: Int?
            if let startsAt, let span = resetsAt?.timeIntervalSince(startsAt), span > 0, span <= 527_040 * 60 {
                minutes = Int(span / 60)
            }
            return .init(id: id, usedPercent: usedPercent, windowMinutes: minutes, resetsAt: resetsAt)
        }

        /// Resource IDs are the provider's stable per-package identity and fit
        /// the extra-key character set, so packages keep their windows across
        /// refreshes even when several packs of one kind coexist.
        func extraKey(fallbackIndex: Int) -> String {
            id.isEmpty ? "wb-\(fallbackIndex)" : id
        }
    }
}

/// `NativeFlexibleDate` has no shape for the billing API's naive
/// `"yyyy-MM-dd HH:mm:ss"` strings; the desktop app parses them as local time,
/// so the same clock applies here.
struct WorkBuddyLocalTimestamp: Decodable {
    let value: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = WorkBuddyClock.parse(text)
        } else if let number = try? container.decode(Double.self) {
            value = NativeFlexibleDate.date(fromEpochLike: number)
        } else {
            value = nil
        }
    }
}

enum WorkBuddyClock {
    static func parse(_ raw: String) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else {
            return NativeAPIParsing.date(raw)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    /// The API filters by a naive local-time range, mirroring the desktop app.
    static func nowText(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: now)
    }
}
