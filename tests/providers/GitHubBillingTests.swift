import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

/// Fixed, synthetic samples shaped after the official 2026-03-10 API docs.
/// No live tokens, payment data, user accounts or paid requests are involved.
final class GitHubBillingTests: XCTestCase, @unchecked Sendable {
    private let now = QuotaRules.date("2026-10-07T12:00:00Z")!
    private let credential = NativeProviderCredential(kind: .apiKey, value: "ghp_SYNTHETIC_ONLY")
    private static let user = Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8)
    private static let org = Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8)
    private static func summary(owner: String = #""user":"demo-user""#, amount: String = "8") -> Data {
        Data(#"{"timePeriod":{"year":2026},\#(owner),"usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.008,"grossQuantity":1000,"grossAmount":8,"discountQuantity":0,"discountAmount":0,"netQuantity":1000,"netAmount":\#(amount)}]}"#.utf8)
    }
    private static let budget = #"{"id":"synthetic-budget","budget_type":"ProductPricing","budget_product_skus":["actions"],"budget_scope":"organization","budget_amount":100,"prevent_further_usage":true,"budget_alerting":{"alert_recipients":["DO_NOT_EXPORT@example.invalid"]}}"#
    private static func page(_ budgets: String = budget, next: Bool = false, total: Int = 1) -> Data {
        Data(#"{"budgets":[\#(budgets)],"has_next_page":\#(next),"total_count":\#(total)}"#.utf8)
    }

    func testPersonalExpenseUsesNetAndNoInventedRemainingOrReset() throws {
        let identity = try GitHubBillingReader.parseIdentity(Self.user, organization: nil)
        let data = Self.summary(amount: "2.5")
        let usage = try GitHubBillingReader.parseUsage(data, identity: identity, organization: false, now: now)
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "github-actions", alias: "Demo", source: .officialAPI)
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(window.quotaKey, "cost-spend")
        XCTAssertEqual(window.amount, "2.5")
        XCTAssertEqual(window.currency, "USD")
        XCTAssertNil(window.limit)
        XCTAssertNil(window.remainingBps)
        XCTAssertNil(window.window.resetsAt)
        XCTAssertEqual(window.window.startsAt.flatMap(QuotaRules.date), QuotaRules.date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(GitHubActionsReporting.queryMonth(window), "2026-10")
        XCTAssertTrue(window.isConsumptionMetric)
        XCTAssertEqual(QuotaPresentation(window: window, now: now).state, .fresh)
        // Stable numeric identity, independent of token or login rename.
        let renamed = try GitHubBillingReader.parseIdentity(Data(#"{"id":123,"login":"renamed","type":"User"}"#.utf8), organization: nil)
        let other = try GitHubBillingReader.parseUsage(Self.summary(owner: #""user":"renamed""#), identity: renamed, organization: false, now: now)
        XCTAssertEqual(try NativeProviderNormalizer.normalize(other, providerID: "github-actions", alias: "Renamed", source: .officialAPI).accountID, result.accountID)
    }

    func testExplicitZeroIsFreshSpendButEmptyOrMissingNumbersRemainUnknown() throws {
        let identity = try GitHubBillingReader.parseIdentity(Self.user, organization: nil)
        let zero = try GitHubBillingReader.parseUsage(Self.summary(amount: "0"), identity: identity, organization: false, now: now)
        let window = try XCTUnwrap(NativeProviderNormalizer.normalize(zero, providerID: "github-actions", alias: "Demo", source: .officialAPI).windows.first)
        XCTAssertEqual(window.amount, "0")
        XCTAssertEqual(QuotaPresentation(window: window, now: now).state, .fresh)
        let original = String(decoding: Self.summary(), as: UTF8.self)
        let invalid = [
            #"{"timePeriod":{"year":2026},"user":"demo-user","usageItems":[]}"#,
            original.replacingOccurrences(of: ",\"netAmount\":8", with: ""),
            original.replacingOccurrences(of: "\"netAmount\":8", with: "\"netAmount\":null"),
            original.replacingOccurrences(of: "\"netAmount\":8", with: "\"netAmount\":-1"),
            original.replacingOccurrences(of: "\"netAmount\":8", with: "\"netAmount\":1e309"),
            original.replacingOccurrences(of: "\"netAmount\":8", with: "\"netAmount\":8,\"currency\":\"EUR\""),
            original.replacingOccurrences(of: "\"product\":\"Actions\"", with: "\"product\":\"Packages\""),
            original.replacingOccurrences(of: "\"year\":2026", with: "\"year\":2025"),
            original.replacingOccurrences(of: "\"year\":2026", with: "\"year\":2026,\"month\":9"),
            original.replacingOccurrences(of: "\"year\":2026", with: "\"year\":2026,\"day\":7"),
            original + "broken"
        ]
        for raw in invalid {
            XCTAssertThrowsError(try GitHubBillingReader.parseUsage(Data(raw.utf8), identity: identity, organization: false, now: now))
        }
        XCTAssertThrowsError(try GitHubBillingReader.parseUsage(Data(repeating: 65, count: NativeHTTP.maxResponseBytes + 1), identity: identity, organization: false, now: now))
    }

    func testOwnerAndPersonalOrganizationIdentityCannotCross() throws {
        let personal = try GitHubBillingReader.parseIdentity(Self.user, organization: nil)
        let org = try GitHubBillingReader.parseIdentity(Self.org, organization: "demo-org")
        XCTAssertThrowsError(try GitHubBillingReader.parseIdentity(Self.org, organization: nil))
        XCTAssertThrowsError(try GitHubBillingReader.parseIdentity(Self.org, organization: "other-org"))
        XCTAssertThrowsError(try GitHubBillingReader.parseUsage(Self.summary(owner: #""user":"other""#), identity: personal, organization: false, now: now))
        XCTAssertThrowsError(try GitHubBillingReader.parseUsage(Self.summary(), identity: org, organization: true, now: now))
        let usage = try GitHubBillingReader.parseUsage(Self.summary(owner: #""organization":"demo-org""#), identity: org, organization: true, now: now)
        XCTAssertEqual(usage.identity.accountID, "organization:456")
        XCTAssertEqual(usage.cost?.periodID, "github-actions-organization-2026-10")
    }

    func testMixedRunnerAndStorageUnitsOnlySumNetUSDAndUTCMonth() throws {
        let identity = try GitHubBillingReader.parseIdentity(Self.user, organization: nil)
        let raw = #"{"timePeriod":{"year":2026,"month":10},"user":"demo-user","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","grossQuantity":2000,"discountQuantity":1000,"grossAmount":16,"discountAmount":8,"netAmount":8},{"product":"Actions","sku":"actions_storage","unitType":"gigabyte-hours","grossQuantity":100000,"netAmount":2}]}"#
        let usage = try GitHubBillingReader.parseUsage(Data(raw.utf8), identity: identity, organization: false, now: now)
        XCTAssertEqual(usage.cost?.used, 10)
        XCTAssertNil(usage.primary)
        XCTAssertTrue(usage.extraWindows.isEmpty)
        let nearBoundary = QuotaRules.date("2026-11-01T00:30:00+09:00")!
        let url = try GitHubBillingReader.usageURL(owner: "demo-user", organization: false, now: nearBoundary)
        XCTAssertTrue(url.absoluteString.contains("month=10"))
        XCTAssertFalse(url.absoluteString.contains("month=11"))
    }

    func testOptionalBudgetFailuresKeepUsageWithoutClaimingBudgetOrBlocking() async throws {
        let credential = NativeProviderCredential(kind: .apiKey, value: "ghs_SYNTHETIC_ONLY", organizationID: "demo-org")
        for failure in [ProviderFailure.authRequired, .unsupported, .network, .rateLimited(seconds: 300), .parseChanged] {
            let spy = RequestSpy(responses: [Self.user, Self.org, Self.summary(owner: #""organization":"demo-org""#)], failure: failure)
            let report = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
                request: { url, headers in try await spy.read(url, headers) })
            XCTAssertEqual(report.budgetState, .unavailable)
            XCTAssertTrue(report.budgets.isEmpty)
            XCTAssertEqual(report.usage.cost?.used, 8)
        }
    }

    func testPersonalTransportQueriesUTCMonthAndNeverBudgets() async throws {
        let spy = RequestSpy(responses: [Self.user, Self.summary()])
        let report = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
            request: { url, headers in try await spy.read(url, headers) })
        XCTAssertEqual(report.budgetState, .personalNotSupported)
        XCTAssertTrue(report.budgets.isEmpty)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.path, "/user")
        XCTAssertEqual(requests[1].url.path, "/users/demo-user/settings/billing/usage/summary")
        XCTAssertEqual(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems,
                       [.init(name: "year", value: "2026"), .init(name: "month", value: "10"), .init(name: "product", value: "Actions")])
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "api.github.com" && $0.url.scheme == "https" && $0.headers["X-GitHub-Api-Version"] == "2026-03-10" && $0.headers["Authorization"] == "Bearer ghp_SYNTHETIC_ONLY" })
    }

    func testOrganizationBudgetIsOptionalAndNeverSubtractsMonthlyCost() async throws {
        let credential = NativeProviderCredential(kind: .apiKey, value: "ghs_SYNTHETIC_ONLY", organizationID: "demo-org")
        let summary = Self.summary(owner: #""organization":"demo-org""#, amount: "150")
        let spy = RequestSpy(responses: [Self.user, Self.org, summary, Self.page()])
        let report = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
            request: { url, headers in try await spy.read(url, headers) })
        XCTAssertEqual(report.budgetState, .available)
        XCTAssertEqual(report.budgets.first?.amount, 100)
        XCTAssertEqual(report.budgets.first?.preventsFurtherUsage, true)
        XCTAssertEqual(report.usage.cost?.used, 150)
        XCTAssertNil(report.usage.cost?.balance)
        XCTAssertEqual(report.usage.cost?.limit, 0)
        let requests = await spy.requests
        XCTAssertEqual(requests.first?.url.path, "/user")
        XCTAssertEqual(requests[1].url.path, "/orgs/demo-org")
        XCTAssertEqual(requests.last?.url.path, "/organizations/demo-org/settings/billing/budgets")
        let failed = RequestSpy(responses: [Self.user, Self.org, summary], failure: .permissionDenied)
        let retained = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
            request: { url, headers in try await failed.read(url, headers) })
        XCTAssertEqual(retained.budgetState, .permissionDenied)
        XCTAssertEqual(retained.usage.cost?.used, 150)
        XCTAssertTrue(retained.budgets.isEmpty)
        let regular = RequestSpy(responses: [Self.user, Self.org, summary])
        _ = try await GitHubBillingReader.load(credential, now: now, includeBudgets: false,
            request: { url, headers in try await regular.read(url, headers) })
        let regularCount = await regular.requestCount()
        XCTAssertEqual(regularCount, 3)
    }

    func testOnlyExactOrganizationActionsProductCapsAreEligible() throws {
        let unrelated = [Self.budget.replacingOccurrences(of: "organization", with: "repository"),
                         Self.budget.replacingOccurrences(of: "ProductPricing", with: "SkuPricing"),
                         Self.budget.replacingOccurrences(of: "actions", with: "packages"),
                         Self.budget.replacingOccurrences(of: "[\"actions\"]", with: "[\"actions\",\"packages\"]")]
        let distinct = unrelated.enumerated().map { $0.element.replacingOccurrences(of: "synthetic-budget", with: "excluded-\($0.offset)") }
        XCTAssertTrue(try GitHubBillingReader.parseBudgets(Self.page(distinct.joined(separator: ","), total: 4)).budgets.isEmpty)
        let singular = Self.budget.replacingOccurrences(of: "\"budget_product_skus\":[\"actions\"]", with: "\"budget_product_sku\":\"actions\"")
        XCTAssertEqual(try GitHubBillingReader.parseBudgets(Self.page(singular)).budgets.first?.amount, 100)
        for amount in ["-1", "1.5", "1e309", "null"] {
            XCTAssertThrowsError(try GitHubBillingReader.parseBudgets(Self.page(Self.budget.replacingOccurrences(of: "\"budget_amount\":100", with: "\"budget_amount\":" + amount))))
        }
    }

    func testBudgetPaginationIsBoundedAndDuplicateOrTruncatedResultsNotComplete() async throws {
        let credential = NativeProviderCredential(kind: .apiKey, value: "ghs_SYNTHETIC_ONLY", organizationID: "demo-org")
        let summary = Self.summary(owner: #""organization":"demo-org""#)
        let pages = (1...3).map { Self.page(Self.budget.replacingOccurrences(of: "synthetic-budget", with: "budget-\($0)"), next: true, total: 4) }
        let spy = RequestSpy(responses: [Self.user, Self.org, summary] + pages)
        let report = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
            request: { url, headers in try await spy.read(url, headers) })
        XCTAssertEqual(report.budgetState, .incomplete)
        let count = await spy.requestCount()
        XCTAssertEqual(count, 6)
        for responses in [[Self.page(next: true, total: 2), Self.page(total: 2)], [Self.page(total: 2)]] {
            let bad = RequestSpy(responses: [Self.user, Self.org, summary] + responses)
            let report = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
                request: { url, headers in try await bad.read(url, headers) })
            XCTAssertEqual(report.budgetState, .unavailable)
            XCTAssertTrue(report.budgets.isEmpty)
            XCTAssertEqual(report.usage.cost?.used, 8)
        }
    }

    func testScopeURLInjectionAndHeaderInjectionRejectedBeforeRequest() async throws {
        for scope in ["../other", "demo?org=x", "demo%2Fother", "https://github.com", "-bad", "bad-", String(repeating: "a", count: 40)] {
            XCTAssertFalse(GitHubBillingReader.validOwner(scope))
            XCTAssertThrowsError(try GitHubBillingReader.usageURL(owner: scope, organization: true, now: now))
            do {
                _ = try await GitHubBillingReader.load(.init(kind: .apiKey, value: "ghp_SYNTHETIC_ONLY", organizationID: scope), now: now, includeBudgets: true,
                    request: { _, _ in XCTFail("Invalid scope must not make a request"); return Data() })
                XCTFail("Invalid scope accepted")
            } catch { XCTAssertEqual(error as? ProviderFailure, .parseChanged) }
        }
        do {
            _ = try await GitHubBillingReader.load(.init(kind: .apiKey, value: "ghp_bad\r\nHeader: evil"), now: now, includeBudgets: false,
                request: { _, _ in XCTFail("Invalid header must not make a request"); return Data() })
            XCTFail("Invalid token accepted")
        } catch { XCTAssertEqual(error as? ProviderFailure, .parseChanged) }
    }

    func testFilteredBudgetDuplicatesAndCancellationCannotBecomeCompleteSettings() async throws {
        let credential = NativeProviderCredential(kind: .apiKey, value: "ghs_SYNTHETIC_ONLY", organizationID: "demo-org")
        let summary = Self.summary(owner: #""organization":"demo-org""#)
        let excluded = Self.budget.replacingOccurrences(of: "actions", with: "packages")
        XCTAssertThrowsError(try GitHubBillingReader.parseBudgets(Self.page(excluded + "," + excluded, total: 2)))
        let duplicate = RequestSpy(responses: [Self.user, Self.org, summary, Self.page(excluded, next: true, total: 2), Self.page(excluded, total: 2)])
        let result = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
            request: { url, headers in try await duplicate.read(url, headers) })
        XCTAssertEqual(result.budgetState, .unavailable)
        XCTAssertTrue(result.budgets.isEmpty)
        XCTAssertEqual(result.usage.cost?.used, 8)
        let cancelled = RequestSpy(responses: [Self.user, Self.org, summary], failure: .cancelled)
        do {
            _ = try await GitHubBillingReader.load(credential, now: now, includeBudgets: true,
                request: { url, headers in try await cancelled.read(url, headers) })
            XCTFail("Cancellation must propagate, not become budget unavailability")
        } catch { XCTAssertEqual(error as? ProviderFailure, .cancelled) }
    }

    func testBillingPermissionUnavailableAndRateLimitAreNotFinancialExhaustion() {
        XCTAssertEqual(GitHubBillingReader.classify(NativeHTTP.Failure.httpStatus(401)), .authRequired)
        XCTAssertEqual(GitHubBillingReader.classify(NativeHTTP.Failure.httpStatus(403)), .permissionDenied)
        XCTAssertEqual(GitHubBillingReader.classify(NativeHTTP.Failure.httpStatus(404)), .unsupported)
        XCTAssertEqual(GitHubBillingReader.classify(NativeHTTP.Failure.httpStatus(429)), .rateLimited(seconds: 300))
        XCTAssertEqual(GitHubBillingReader.classify(NativeHTTP.Failure.httpStatus(503)), .network)
        XCTAssertEqual(NativeProviderCatalog.supportedCredentialKinds(providerID: "github-actions"), [.apiKey])
        XCTAssertEqual(ProviderCatalog.identity(for: "github-actions").displayName, "GitHub Actions")
        XCTAssertNotEqual(ProviderCatalog.identity(for: "github-actions"), ProviderCatalog.identity(for: "copilot"))
    }
}

private actor RequestSpy {
    struct Recorded: Sendable { let url: URL; let headers: [String: String] }
    var requests: [Recorded] = []
    private var responses: [Data]
    private let failure: ProviderFailure
    init(responses: [Data], failure: ProviderFailure = .network) { self.responses = responses; self.failure = failure }
    func read(_ url: URL, _ headers: [String: String]) throws -> Data {
        requests.append(.init(url: url, headers: headers))
        guard !responses.isEmpty else { throw failure }
        return responses.removeFirst()
    }
    func requestCount() -> Int { requests.count }
}
