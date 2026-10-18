import Foundation
import QuotaCore

/// Local-only configuration. Never put a budget cap in a remaining/balance
/// quota window: GitHub does not expose the budget's metered consumption.
public struct GitHubActionsBudget: Identifiable, Sendable {
    public let id: String
    public let amount: Double
    public let preventsFurtherUsage: Bool
}

public struct GitHubBillingReport: Sendable {
    public enum BudgetState: Sendable, Equatable {
        case personalNotSupported, available, permissionDenied, unavailable, incomplete
    }
    public let usage: NativeUsage
    /// A verified target, independent of optional billing permissions.
    public let owner: String
    public let expenseFailure: ProviderFailure?
    public let budgets: [GitHubActionsBudget]
    public let budgetState: BudgetState
    public var retryNotBefore: Date? = nil
    public var expenseObservedAt: Date? = nil
    public var queryDate: Date? = nil
}

struct GitHubIdentityReadFailure: Error, Sendable {
    let reason: ProviderFailure
}

struct GitHubBillingBindingFailure: Error, Sendable {}

/// Official billing endpoints only. The caller supplies an already-authorized
/// credential from Ammo's existing vault; no gh import, OAuth or scope changes.
public enum GitHubBillingReader {
    typealias Request = @Sendable (URL, [String: String]) async throws -> Data
    static let apiVersion = "2026-03-10"
    private static let maxBudgetPages = 3

    public static func validOwner(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$",
                    options: .regularExpression) != nil
    }

    public static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        try await load(credential, includeBudgets: false).usage
    }

    public static func report(_ credential: NativeProviderCredential, includeBudgets: Bool = true) async throws -> GitHubBillingReport {
        try await load(credential, includeBudgets: includeBudgets)
    }

    // Injectable bounded transport for fixed, synthetic official-shaped fixtures.
    static func load(_ credential: NativeProviderCredential, now: Date = Date(),
                     includeBudgets: Bool,
                     request: Request = liveRequest) async throws -> GitHubBillingReport {
        try credential.validated()
        guard credential.kind == .apiKey, credential.workspaceID == nil, credential.region == nil,
              credential.value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ProviderFailure.parseChanged
        }
        let organization = credential.organizationID
        if let organization, !validOwner(organization) { throw ProviderFailure.parseChanged }
        let headers = ["Authorization": "Bearer " + credential.value,
                       "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": apiVersion]
        return try await load(organization: organization, now: now, includeBudgets: includeBudgets,
                              headers: headers, request: request)
    }

    /// Shared parsing/identity/budget rules; CLI callers supply no Authorization.
    static func load(organization: String?, now: Date, includeBudgets: Bool,
                     headers: [String: String], request: Request,
                     validateIdentity: @Sendable (Identity) throws -> Void = { _ in }) async throws -> GitHubBillingReport {
        if let organization, !validOwner(organization) { throw ProviderFailure.parseChanged }
        try Task.checkCancellation()
        // /orgs is public metadata. An authenticated /user is required even
        // when all organization billing sources are unavailable.
        let identity = try await readIdentity(organization: organization, headers: headers, request: request)
        try validateIdentity(identity)
        let usageURL = try usageURL(owner: identity.login, organization: organization != nil, now: now)
        var usage = NativeUsage(identity: .init(accountID: "\(organization == nil ? "user" : "organization"):\(identity.id)"), updatedAt: now)
        var expenseFailure: ProviderFailure?
        var retryNotBefore: Date?
        var expenseObservedAt = Date()
        do {
            let data = try await request(usageURL, headers)
            expenseObservedAt = Date()
            do { usage = try parseUsage(data, identity: identity, organization: organization != nil, now: now, observedAt: expenseObservedAt) }
            catch ProviderFailure.authRequired { throw GitHubBillingBindingFailure() }
        } catch {
            try propagateCancellation(error)
            if error is GitHubBillingBindingFailure { throw ProviderFailure.authRequired }
            expenseObservedAt = Date()
            usage = NativeUsage(identity: usage.identity, updatedAt: expenseObservedAt)
            expenseFailure = classify(error)
            retryNotBefore = retryDate(error, receivedAt: expenseObservedAt)
        }
        guard organization != nil, includeBudgets else {
            return .init(usage: usage, owner: identity.login, expenseFailure: expenseFailure,
                         budgets: [], budgetState: .personalNotSupported, retryNotBefore: retryNotBefore, expenseObservedAt: expenseObservedAt, queryDate: now)
        }
        // GitHub rate limits apply to the shared login. Optional-source
        // independence must not issue another request after a rate limit.
        if case .rateLimited = expenseFailure {
            return .init(usage: usage, owner: identity.login, expenseFailure: expenseFailure,
                         budgets: [], budgetState: .unavailable, retryNotBefore: retryNotBefore, expenseObservedAt: expenseObservedAt, queryDate: now)
        }
        do {
            var budgets: [GitHubActionsBudget] = []
            var seen = Set<String>()
            var total: Int?
            var rowCount = 0
            for page in 1...maxBudgetPages {
                try Task.checkCancellation()
                let endpoint = try url(path: "/organizations/\(identity.login)/settings/billing/budgets",
                    query: [.init(name: "scope", value: "organization"), .init(name: "per_page", value: "100"),
                            .init(name: "page", value: String(page))])
                let result = try parseBudgets(await request(endpoint, headers))
                if let total, total != result.totalCount { throw ProviderFailure.parseChanged }
                total = result.totalCount
                rowCount += result.rowCount
                for id in result.rawIDs {
                    guard seen.insert(id).inserted else { throw ProviderFailure.parseChanged }
                }
                budgets.append(contentsOf: result.budgets)
                if !result.hasNextPage {
                    guard rowCount == result.totalCount else { throw ProviderFailure.parseChanged }
                    return .init(usage: usage, owner: identity.login, expenseFailure: expenseFailure,
                                 budgets: budgets, budgetState: .available, retryNotBefore: retryNotBefore, expenseObservedAt: expenseObservedAt, queryDate: now)
                }
            }
            return .init(usage: usage, owner: identity.login, expenseFailure: expenseFailure,
                         budgets: budgets, budgetState: .incomplete, retryNotBefore: retryNotBefore, expenseObservedAt: expenseObservedAt, queryDate: now)
        } catch {
            try propagateCancellation(error)
            return .init(usage: usage, owner: identity.login, expenseFailure: expenseFailure, budgets: [],
                         budgetState: classify(error) == .permissionDenied ? .permissionDenied : .unavailable,
                         retryNotBefore: retryDate(error, receivedAt: Date()) ?? retryNotBefore,
                         expenseObservedAt: expenseObservedAt, queryDate: now)
        }
    }

    static func retryDate(_ error: Error, receivedAt: Date) -> Date? {
        if let limited = error as? GitHubRateLimitFailure { return limited.retryNotBefore }
        if case let .rateLimited(seconds) = error as? ProviderFailure {
            return receivedAt.addingTimeInterval(Double(max(1, seconds)))
        }
        return nil
    }

    private static func propagateCancellation(_ error: Error) throws {
        if Task.isCancelled || error is CancellationError || (error as? ProviderFailure) == .cancelled {
            throw ProviderFailure.cancelled
        }
    }

    private static func readIdentity(organization: String?, headers: [String: String], request: Request) async throws -> Identity {
        do {
            let authenticated = try parseIdentity(await request(url(path: "/user"), headers), organization: nil)
            guard let organization else { return authenticated }
            return try parseIdentity(await request(url(path: "/orgs/\(organization)"), headers), organization: organization)
        } catch {
            try propagateCancellation(error)
            throw GitHubIdentityReadFailure(reason: classify(error))
        }
    }

    /// Only GitHub can accept an independently verified identity without cost.
    /// All other native adapters keep their existing empty-result rejection.
    public static func normalized(_ report: GitHubBillingReport, alias: String) throws -> NativeProviderNormalizationResult {
        if report.expenseFailure == nil {
            var result = try NativeProviderNormalizer.normalize(report.usage, providerID: "github-actions", alias: alias, source: .officialAPI)
            result.retryNotBefore = report.retryNotBefore
            result.expenseObservedAt = report.expenseObservedAt
            return result
        }
        guard !alias.isEmpty, alias.count <= 48, report.usage.cost == nil else { throw ProviderFailure.parseChanged }
        let pin = try NativeProviderNormalizer.identity(report.usage, providerID: "github-actions")
        let accountID = "native-" + String(pin.prefix(32))
        let outcome: FetchOutcome
        if case .rateLimited = report.expenseFailure { outcome = .throttled } else { outcome = .error }
        let period = month(report.queryDate ?? report.usage.updatedAt)
        let scope = report.usage.identity.accountID?.hasPrefix("organization:") == true ? "organization" : "user"
        let window = QuotaWindow.providerValue(
            id: NativeProviderNormalizer.stableWindowID(providerID: "github-actions", accountID: accountID, key: "cost-spend"),
            providerID: "github-actions", accountID: accountID, alias: alias, key: "cost-spend",
            unit: .money, currency: "USD", availability: .unavailable,
            remainingBps: nil, amount: nil, limit: nil, quality: .unknown, source: .officialAPI, outcome: outcome,
            observedAt: report.usage.updatedAt, staleAt: report.usage.updatedAt,
            windowKind: .calendar, duration: nil, resetsAt: nil, startsAt: period.start,
            periodID: String(format: "github-actions-%@-%04d-%02d", scope, period.year, period.month))
        return .init(windows: [window], identityFingerprint: pin, accountID: accountID,
                     retryNotBefore: report.retryNotBefore, expenseObservedAt: report.expenseObservedAt)
    }

    private static func liveRequest(_ url: URL, _ headers: [String: String]) async throws -> Data {
        let key = GitHubRequestGate.key(forAuthorization: headers["Authorization"] ?? "")
        do { return try await GitHubRequestGate.shared.request(key: key) {
            try await NativeHTTP.request("GET", url, headers: headers, githubRateLimits: true).data
        } }
        catch let error as GitHubRateLimitFailure { throw error }
        catch { throw classify(error) }
    }

    static func classify(_ error: Error) -> ProviderFailure {
        if let failure = error as? GitHubIdentityReadFailure { return failure.reason }
        if error is GitHubBillingBindingFailure { return .authRequired }
        if let failure = error as? GitHubRateLimitFailure { return .rateLimited(seconds: failure.secondsRemaining()) }
        if let failure = error as? ProviderFailure { return failure }
        if let failure = error as? GitHubCLIFailure {
            return switch failure {
            case .notLoggedIn: .authRequired
            case .billingDenied, .unsafeExecutable: .permissionDenied
            case .notInstalled, .billingUnavailable: .unsupported
            }
        }
        // GitHub deliberately uses 404 for some inaccessible resources. It is
        // not evidence of either an invalid token or an exhausted spending cap.
        if case NativeHTTP.Failure.httpStatus(404) = error { return .unsupported }
        return NativeHTTP.classify(error)
    }

    public static func localizedError(_ error: Error) -> String {
        errorStatus(error).text
    }

    public static func errorStatus(_ error: Error) -> LocalizedStatus {
        if error is GitHubIdentityReadFailure { return LocalizedStatus("billing.github.identityUnavailable") }
        if let failure = error as? GitHubCLIFailure {
            let key = switch failure {
            case .notInstalled: "billing.github.cli.notInstalled"
            case .unsafeExecutable: "billing.github.cli.unsafeExecutable"
            case .notLoggedIn: "billing.github.cli.notLoggedIn"
            case .billingUnavailable: "billing.github.cli.unavailable"
            case .billingDenied: "billing.github.cli.denied"
            }
            return LocalizedStatus(key)
        }
        let key = switch classify(error) {
        case .authRequired: "billing.github.error.auth"
        case .permissionDenied: "billing.github.error.permission"
        case .unsupported: "billing.github.error.unavailable"
        case .rateLimited: "billing.github.error.rateLimited"
        default: "billing.github.error.failed"
        }
        return LocalizedStatus(key)
    }

    struct Identity: Decodable, Sendable {
        let id: UInt64
        let login: String
        let type: String
    }

    static func parseIdentity(_ data: Data, organization: String?) throws -> Identity {
        let identity = try NativeHTTP.decode(Identity.self, from: data)
        guard identity.id > 0, validOwner(identity.login),
              identity.type == (organization == nil ? "User" : "Organization") else {
            throw ProviderFailure.parseChanged
        }
        if let organization, identity.login.caseInsensitiveCompare(organization) != .orderedSame {
            throw ProviderFailure.authRequired
        }
        return identity
    }

    private struct SummaryOwner: Decodable {
        let user: String?
        let organization: String?
    }
    private struct Summary: Decodable {
        struct Period: Decodable { let year: Int; let month: Int?; let day: Int? }
        struct Item: Decodable {
            let product: String
            let sku: String
            let unitType: String
            let netAmount: Double
            let currency: String?
        }
        let timePeriod: Period
        let user: String?
        let organization: String?
        let usageItems: [Item]
    }

    static func parseUsage(_ data: Data, identity: Identity, organization: Bool, now: Date, observedAt: Date? = nil) throws -> NativeUsage {
        guard data.count <= NativeHTTP.maxResponseBytes else { throw ProviderFailure.outputLimit }
        let binding: SummaryOwner
        do { binding = try JSONDecoder().decode(SummaryOwner.self, from: data) }
        catch DecodingError.typeMismatch { throw ProviderFailure.authRequired }
        catch { throw ProviderFailure.parseChanged }
        let owner = organization ? binding.organization : binding.user
        guard owner?.caseInsensitiveCompare(identity.login) == .orderedSame,
              organization ? binding.user == nil : binding.organization == nil else {
            throw ProviderFailure.authRequired
        }
        let summary = try NativeHTTP.decode(Summary.self, from: data)
        let period = month(now)
        guard summary.timePeriod.year == period.year,
              summary.timePeriod.month == nil || summary.timePeriod.month == period.month,
              summary.timePeriod.day == nil,
              !summary.usageItems.isEmpty, summary.usageItems.count <= 10_000 else {
            // An empty report carries no measured zero; leave usage unknown.
            throw ProviderFailure.parseChanged
        }
        var total = 0.0
        for item in summary.usageItems {
            guard item.product.caseInsensitiveCompare("Actions") == .orderedSame,
                  !item.sku.isEmpty, item.sku.utf8.count <= 256,
                  !item.unitType.isEmpty, item.unitType.utf8.count <= 64,
                  item.currency == nil || item.currency == "USD",
                  item.netAmount.isFinite, (0...1_000_000_000_000).contains(item.netAmount) else {
                throw ProviderFailure.parseChanged
            }
            // Costs are additive in USD; runner minutes and storage are not.
            total += item.netAmount
            guard total.isFinite, total <= 1_000_000_000_000 else { throw ProviderFailure.parseChanged }
        }
        let scope = organization ? "organization" : "user"
        return NativeUsage(cost: .init(used: total, limit: 0, balance: nil, currency: "USD", period: "monthly",
            reportsSpend: true, startsAt: period.start,
            periodID: String(format: "github-actions-%@-%04d-%02d", scope, period.year, period.month)),
            identity: .init(accountID: "\(scope):\(identity.id)"), updatedAt: observedAt ?? now)
    }

    private struct BudgetPage: Decodable {
        struct Budget: Decodable {
            let id: String
            let budget_type: String
            let budget_scope: String
            let budget_product_skus: [String]?
            let budget_product_sku: String?
            let budget_amount: Double?
            let prevent_further_usage: Bool?
            // Deliberately omit entity names, alerts and recipients.
        }
        let budgets: [Budget]
        let has_next_page: Bool
        let total_count: Int
    }

    struct ParsedBudgets {
        let budgets: [GitHubActionsBudget]
        let hasNextPage: Bool
        let totalCount: Int
        let rowCount: Int
        let rawIDs: [String]
    }

    static func parseBudgets(_ data: Data) throws -> ParsedBudgets {
        let page = try NativeHTTP.decode(BudgetPage.self, from: data)
        guard page.budgets.count <= 100, page.total_count >= page.budgets.count,
              page.total_count <= 100_000, !page.has_next_page || !page.budgets.isEmpty else {
            throw ProviderFailure.parseChanged
        }
        var budgets: [GitHubActionsBudget] = []
        var rawIDs: [String] = []
        var seen = Set<String>()
        for raw in page.budgets {
            guard !raw.id.isEmpty, raw.id.utf8.count <= 128,
                  !raw.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(raw.id).inserted else { throw ProviderFailure.parseChanged }
            rawIDs.append(raw.id)
            guard raw.budget_type == "ProductPricing", raw.budget_scope == "organization" else { continue }
            let skus = raw.budget_product_skus ?? raw.budget_product_sku.map { [$0] } ?? []
            guard skus.map({ $0.lowercased() }) == ["actions"] else { continue }
            guard let amount = raw.budget_amount, amount.isFinite,
                  (0...1_000_000_000_000).contains(amount), amount.rounded() == amount,
                  let prevents = raw.prevent_further_usage else { throw ProviderFailure.parseChanged }
            budgets.append(.init(id: raw.id, amount: amount, preventsFurtherUsage: prevents))
        }
        return .init(budgets: budgets, hasNextPage: page.has_next_page, totalCount: page.total_count,
                     rowCount: page.budgets.count, rawIDs: rawIDs)
    }

    static func usageURL(owner: String, organization: Bool, now: Date) throws -> URL {
        guard validOwner(owner) else { throw ProviderFailure.parseChanged }
        let period = month(now)
        return try url(path: "/\(organization ? "organizations" : "users")/\(owner)/settings/billing/usage/summary",
            query: [.init(name: "year", value: String(period.year)), .init(name: "month", value: String(period.month)),
                    .init(name: "product", value: "Actions")])
    }

    private static func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.github.com"; components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderFailure.parseChanged }
        return url
    }

    private static func month(_ now: Date) -> (year: Int, month: Int, start: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: now)
        return (components.year!, components.month!, calendar.date(from: components)!)
    }
}
