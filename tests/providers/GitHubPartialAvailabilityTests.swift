import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

private actor PartialRequestTrace {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

final class GitHubPartialAvailabilityTests: XCTestCase, @unchecked Sendable {
    private let now = QuotaRules.date("2026-10-08T00:00:00Z")!
    private static let user = Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8)
    private static let org = Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8)
    private static let usage = Data(#"{"timePeriod":{"year":2026,"month":10},"user":"demo-user","usageItems":[{"product":"Actions","sku":"runner","unitType":"minutes","netAmount":8}]}"#.utf8)
    private static let budget = Data(#"{"budgets":[{"id":"synthetic-budget","budget_type":"ProductPricing","budget_scope":"organization","budget_product_skus":["actions"],"budget_amount":100,"prevent_further_usage":true}],"has_next_page":false,"total_count":1}"#.utf8)

    func testVerifiedIdentityAnd404ProduceSaveableUnknownConnectionForBothMethods() async throws {
        let cli = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, headers in
            XCTAssertNil(headers["Authorization"])
            if url.path == "/user" { return Self.user }
            throw GitHubCLIFailure.billingUnavailable
        }
        let manual = try await GitHubBillingReader.load(.init(kind: .apiKey, value: "SYNTHETIC_ONLY"), now: now, includeBudgets: false) { url, _ in
            if url.path == "/user" { return Self.user }
            throw NativeHTTP.Failure.httpStatus(404)
        }
        for report in [cli, manual] {
            XCTAssertEqual(report.owner, "demo-user")
            XCTAssertEqual(report.expenseFailure, .unsupported)
            let normalized = try GitHubBillingReader.normalized(report, alias: "Synthetic")
            let window = try XCTUnwrap(normalized.windows.first)
            XCTAssertEqual(window.availability, .unavailable)
            XCTAssertEqual(window.quality, .unknown)
            XCTAssertEqual(window.fetchOutcome, .error)
            XCTAssertNil(window.amount); XCTAssertNil(window.limit); XCTAssertNil(window.remainingBps)
            XCTAssertNil(window.window.resetsAt)
            let snapshot = try Snapshot.make(windows: normalized.windows, deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)
            _ = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
            let record = try ProviderConnectionRecord(id: "local-github-test", kind: .githubCLILogin,
                providerID: "github-actions", accountID: normalized.accountID, accountAlias: "Synthetic",
                expectedIdentity: normalized.identityFingerprint).validated()
            let configuration = try ProviderConnectionsConfiguration(deviceID: "synthetic", epoch: "synthetic", connections: [record]).validated()
            let saved = try ProviderConnectionsConfiguration.decodeMigrating(JSONEncoder().encode(configuration)).configuration
            XCTAssertEqual(saved.connections.count, 1)
            XCTAssertEqual(saved.connections.first?.expectedIdentity, normalized.identityFingerprint)
            XCTAssertNil(saved.connections.first?.instanceID)
        }
    }

    func testExpense404DoesNotPreventIndependentBudgetSuccess() async throws {
        let trace = PartialRequestTrace()
        let report = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: now) { url, _ in
            await trace.record(url.path)
            switch url.path {
            case "/user": return Self.user
            case "/orgs/demo-org": return Self.org
            case let path where path.hasSuffix("budgets"): return Self.budget
            default: throw GitHubCLIFailure.billingUnavailable
            }
        }
        XCTAssertEqual(report.expenseFailure, .unsupported)
        XCTAssertNil(report.usage.cost)
        XCTAssertEqual(report.budgetState, .available)
        XCTAssertEqual(report.budgets.first?.amount, 100)
        XCTAssertEqual(report.budgets.first?.preventsFurtherUsage, true)
        let paths = await trace.paths
        XCTAssertEqual(paths, ["/user", "/orgs/demo-org", "/organizations/demo-org/settings/billing/usage/summary", "/organizations/demo-org/settings/billing/budgets"])
        let window = try XCTUnwrap(GitHubBillingReader.normalized(report, alias: "Synthetic").windows.first)
        XCTAssertNil(window.limit); XCTAssertNil(window.amount)
    }

    func testAllOptionalSourcesCanFailAndStillRetainVerifiedIdentity() async throws {
        for failure in [ProviderFailure.unsupported, .permissionDenied, .authRequired, .network, .parseChanged, .rateLimited(seconds: 300)] {
            let trace = PartialRequestTrace()
            let report = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: now) { url, _ in
                await trace.record(url.path)
                if url.path == "/user" { return Self.user }
                if url.path == "/orgs/demo-org" { return Self.org }
                throw failure
            }
            XCTAssertEqual(report.owner, "demo-org")
            XCTAssertEqual(report.expenseFailure, failure)
            XCTAssertTrue(report.budgets.isEmpty)
            let windows = try GitHubBillingReader.normalized(report, alias: "Synthetic").windows
            XCTAssertEqual(windows.count, 1); XCTAssertEqual(windows[0].availability, .unavailable)
            XCTAssertNotEqual(windows[0].fetchOutcome, .authRequired, "Optional billing denial is not invalid identity")
            XCTAssertNil(windows[0].amount)
            let paths = await trace.paths
            if case .rateLimited = failure {
                XCTAssertEqual(paths.count, 3)
                XCTAssertFalse(paths.contains { $0.hasSuffix("budgets") }, "Do not issue more requests on the rate-limited login")
            } else {
                XCTAssertEqual(paths.count, 4)
            }
        }
    }

    func testIdentityFailureAndInvalidScopeCannotBecomeOptionalFailure() async throws {
        for org in [nil, "demo-org"] as [String?] {
            let trace = PartialRequestTrace()
            do {
                _ = try await GitHubCLIProvider.read(organization: org, includeBudgets: true, now: now) { url, _ in
                    await trace.record(url.path)
                    if url.path == "/orgs/demo-org" { return Self.org }
                    throw GitHubCLIFailure.notLoggedIn
                }
                XCTFail("Identity failure must prevent saving, even if organization is public")
            } catch { XCTAssertEqual(GitHubBillingReader.classify(error), .authRequired) }
            let paths = await trace.paths
            XCTAssertEqual(paths, ["/user"])
        }
        do {
            _ = try await GitHubCLIProvider.read(organization: "../other", includeBudgets: true, now: now) { _, _ in
                XCTFail("Invalid target must not make requests"); return Self.user
            }
            XCTFail("Invalid target was accepted")
        } catch { XCTAssertEqual(error as? ProviderFailure, .parseChanged) }
        do {
            _ = try await GitHubCLIProvider.read(organization: nil, includeBudgets: true, now: now) { _, _ in Data(#"{"id":0,"login":"demo-user","type":"User"}"#.utf8) }
            XCTFail("Malformed identity was accepted")
        } catch { XCTAssertEqual(GitHubBillingReader.classify(error), .parseChanged) }
    }

    func testBillingOwnerOrScopeMismatchIsTerminalForCLIAndManualRead() async throws {
        for scope in ["user", "organization"] {
            for payload in [
                Self.usage,
                Data(#"{"timePeriod":"malformed-period","user":"another-user","usageItems":[{"netAmount":"malformed-amount"}]}"#.utf8),
                Data(#"{"timePeriod":{"year":2026,"month":9},"user":"another-user","usageItems":[]}"#.utf8),
                Data(#"{"timePeriod":{"year":2026,"month":10},"user":"another-user","usageItems":[{"product":"Actions","sku":"runner","unitType":"minutes","netAmount":8}]}"#.utf8)
            ] {
                // Organization receives a personal response, or personal owner differs.
                if scope == "user", payload == Self.usage { continue }
                let organization = scope == "organization" ? "demo-org" : nil
                let request: GitHubBillingReader.Request = { url, _ in
                    if url.path == "/user" { return Self.user }
                    if url.path == "/orgs/demo-org" { return Self.org }
                    XCTAssertFalse(url.path.hasSuffix("budgets"), "Binding failure is terminal")
                    return payload
                }
                do {
                    _ = try await GitHubCLIProvider.read(organization: organization, includeBudgets: true, now: now, request: request)
                    XCTFail("CLI accepted another billing owner/scope")
                } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
                do {
                    _ = try await GitHubBillingReader.load(.init(kind: .apiKey, value: "SYNTHETIC_ONLY", organizationID: organization),
                        now: now, includeBudgets: true, request: request)
                    XCTFail("Manual reader accepted another billing owner/scope")
                } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
            }
        }
    }

    func testFailedRefreshDropsCostAndRecoveryUsesSameAccountAndWindow() async throws {
        var windows: [QuotaWindow] = []
        var pins: [String] = []
        for succeeds in [true, false, true] {
            let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
                if url.path == "/user" { return Self.user }
                guard succeeds else { throw GitHubCLIFailure.billingUnavailable }
                return Self.usage
            }
            let result = try GitHubBillingReader.normalized(report, alias: "Synthetic")
            windows.append(try XCTUnwrap(result.windows.first)); pins.append(result.identityFingerprint)
        }
        XCTAssertEqual(Set(windows.map(\.id)).count, 1)
        XCTAssertEqual(Set(windows.map(\.accountId)).count, 1)
        XCTAssertEqual(Set(pins).count, 1)
        XCTAssertEqual(windows.map(\.amount), ["8", nil, "8"])
        XCTAssertEqual(windows.map(\.availability), [.available, .unavailable, .available])
        XCTAssertEqual(windows.map(\.fetchOutcome), [.ok, .error, .ok])
    }

    func testCancellationDuringOptionalExpenseDoesNotContinueToBudgetsOrSave() async throws {
        let trace = PartialRequestTrace()
        do {
            _ = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: now) { url, _ in
                await trace.record(url.path)
                if url.path == "/user" { return Self.user }
                if url.path == "/orgs/demo-org" { return Self.org }
                throw CancellationError()
            }
            XCTFail("Cancellation accepted a connection")
        } catch { XCTAssertEqual(error as? ProviderFailure, .cancelled) }
        let paths = await trace.paths
        XCTAssertFalse(paths.contains { $0.hasSuffix("budgets") })
    }

    func testOptionalRateLimitAllowsUnknownButPreservesRetryDeadlineUntilRecovery() async throws {
        let receivedAfter = Date()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, _ in
            if url.path == "/user" { return Self.user }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        let result = try GitHubBillingReader.normalized(report, alias: "Synthetic")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.retryNotBefore), receivedAfter.addingTimeInterval(600))
        let actual = GitHubCLIProvider(accountID: result.accountID, alias: "Synthetic", expectedIdentity: result.identityFingerprint, organization: nil)
        let windows = try await actual.fetch(now: now) { url, _ in
            if url.path == "/user" { return Self.user }
            throw ProviderFailure.rateLimited(seconds: 600)
        }
        XCTAssertEqual(windows.first?.availability, .unavailable)
        XCTAssertEqual(windows.first?.fetchOutcome, .throttled)
        let deadline = await actual.retryNotBefore()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(deadline), receivedAfter.addingTimeInterval(600))
        _ = try await actual.fetch(now: now.addingTimeInterval(600)) { url, _ in
            url.path == "/user" ? Self.user : Self.usage
        }
        let recoveredDeadline = await actual.retryNotBefore()
        XCTAssertNil(recoveredDeadline)
    }
}
