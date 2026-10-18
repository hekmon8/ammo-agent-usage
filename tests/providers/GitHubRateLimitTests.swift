import Foundation
import XCTest
@testable import QuotaProviders

private actor GateRequestCount {
    var count = 0
    func increment() { count += 1 }
}

final class GitHubRateLimitTests: XCTestCase, @unchecked Sendable {
    func testRawCLI403And429PreserveServerDeadlinesAndPermission403StaysIndependent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (status, headers, expected) in [
            (403, "X-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1800000900", now.addingTimeInterval(900)),
            (403, "Retry-After: 1200", now.addingTimeInterval(1200)),
            (429, "Retry-After: 1800\r\nX-RateLimit-Reset: 1800000900", now.addingTimeInterval(1800))
        ] {
            let output = Data("HTTP/2.0 \(status) Failure\r\n\(headers)\r\n\r\nSYNTHETIC_ERROR".utf8)
            XCTAssertThrowsError(try GitHubCLIProvider.response(.init(output: output, exitCode: 1), now: now)) {
                XCTAssertEqual(($0 as? GitHubRateLimitFailure)?.retryNotBefore, expected)
            }
        }
        let denied = Data("HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 10\r\n\r\n{}".utf8)
        XCTAssertThrowsError(try GitHubCLIProvider.response(.init(output: denied, exitCode: 1), now: now)) {
            XCTAssertEqual($0 as? GitHubCLIFailure, .billingDenied)
        }
    }

    func testDelayedBillingResponseAnchorsRetryToReceiptAndSkipsBudgets() async throws {
        let before = Date()
        let started = before.addingTimeInterval(-120)
        let report = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: started) { url, _ in
            if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
            if url.path == "/orgs/demo-org" { return Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8) }
            XCTAssertFalse(url.path.hasSuffix("budgets"))
            let data = Data("HTTP/2.0 429 Limited\r\nRetry-After: 900\r\n\r\n{}".utf8)
            return try GitHubCLIProvider.response(.init(output: data, exitCode: 1))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.retryNotBefore), before.addingTimeInterval(900))
        XCTAssertEqual(report.budgetState, .unavailable)
    }

    func testBudgetThrottlingKeepsMeasuredExpenseAndSharesDeadlineWithSubsequentReads() async throws {
        let gate = GitHubRequestGate()
        let count = GateRequestCount()
        let key = "synthetic-existing-login"
        let now = Date()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
        let usage = Data("{\"timePeriod\":{\"year\":\(year),\"month\":\(month)},\"organization\":\"demo-org\",\"usageItems\":[{\"product\":\"Actions\",\"sku\":\"runner\",\"unitType\":\"minutes\",\"netAmount\":8}]}".utf8)
        let report = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: now) { url, _ in
            try await gate.request(key: key) {
                await count.increment()
                if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
                if url.path == "/orgs/demo-org" { return Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8) }
                if url.path.hasSuffix("budgets") { throw GitHubRateLimitFailure(retryNotBefore: now.addingTimeInterval(1200)) }
                return usage
            }
        }
        XCTAssertNil(report.expenseFailure)
        XCTAssertEqual(report.usage.cost?.used, 8)
        XCTAssertEqual(report.retryNotBefore, now.addingTimeInterval(1200))
        XCTAssertEqual(try GitHubBillingReader.normalized(report, alias: "Synthetic").windows.first?.amount, "8")
        for _ in 0..<3 {
            do {
                _ = try await gate.request(key: key) { await count.increment(); return Data() }
                XCTFail("Details/probe/collector must all respect the same credential deadline")
            } catch { XCTAssertEqual((error as? GitHubRateLimitFailure)?.retryNotBefore, now.addingTimeInterval(1200)) }
        }
        let calls = await count.count
        XCTAssertEqual(calls, 4)
        let retained = await gate.deadline(key: key)
        XCTAssertEqual(retained, report.retryNotBefore)
        let otherDeadline = await gate.deadline(key: "synthetic-other-credential")
        XCTAssertNil(otherDeadline)
    }

    func testQueuedReadCannotSlipPastRateLimitedInFlightRequest() async throws {
        let gate = GitHubRequestGate()
        let calls = GateRequestCount()
        let due = Date().addingTimeInterval(1200)
        let first = Task {
            try await gate.request(key: "synthetic") {
                await calls.increment()
                try await Task.sleep(for: .milliseconds(50))
                throw GitHubRateLimitFailure(retryNotBefore: due)
            }
        }
        while await calls.count == 0 { await Task.yield() }
        let second = Task {
            try await gate.request(key: "synthetic") { await calls.increment(); return Data() }
        }
        _ = try? await first.value
        _ = try? await second.value
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }
}
