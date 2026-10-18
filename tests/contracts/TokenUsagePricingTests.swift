import Foundation
import XCTest
import QuotaCore

final class TokenUsagePricingTests: XCTestCase {
    func testOfficialModelsCacheAndOutputAreValuedSeparately() throws {
        let counts = TokenUsageCounts(nonCachedInput: 100_000, cacheRead: 50_000, cacheWrite: 10_000, output: 20_000)
        let sol = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6.1-sol", counts: counts, requestInput: 160_000))
        XCTAssertEqual(sol, 0.430, accuracy: 0.000_000_1)
        let luna = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6-luna", counts: counts, requestInput: 160_000))
        XCTAssertEqual(luna, 0.02175, accuracy: 0.000_000_1)
    }
    func testLongContextIsPerRequestAndMissingEvidenceRemainsUnknown() throws {
        let counts = TokenUsageCounts(nonCachedInput: 273_000, output: 100)
        XCTAssertEqual(try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6.1-sol", counts: counts, requestInput: 273_000)), 1.0935, accuracy: 0.000_000_1)
        XCTAssertNil(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6.1-sol", counts: counts, requestInput: nil))
        // Ten ordinary requests do not turn into one long-context request.
        let small = TokenUsageCounts(nonCachedInput: 100_000)
        let each = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6.1-sol", counts: small, requestInput: 100_000))
        XCTAssertEqual(each * 10, 2, accuracy: 0.000_000_1)
    }
    func testUnknownModelsAndWrongProviderDoNotBorrowPrices() {
        for model in [nil, "codex-auto-review", "gpt-6.1-sol-unverified", "future-model"] as [String?] {
            XCTAssertNil(TokenUsagePricing.standardUSD(agent: .codex, model: model, counts: TokenUsageCounts(output: 100), requestInput: 0))
        }
        XCTAssertNil(TokenUsagePricing.rate(agent: .claudeCode, model: "gpt-6.1-sol"))
        XCTAssertNil(TokenUsagePricing.rate(agent: .codex, model: "claude-sonnet-4-6"))
    }
    func testClaudeCacheTTLIsRequiredAndOneHourDoesNotUseFiveMinuteRate() throws {
        let counts = TokenUsageCounts(nonCachedInput: 1_000, cacheRead: 2_000, cacheWrite: 500, output: 100)
        XCTAssertNil(TokenUsagePricing.standardUSD(agent: .claudeCode, model: "claude-sonnet-4-6", counts: counts, requestInput: nil))
        let cost = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .claudeCode, model: "claude-sonnet-4-6", counts: counts, requestInput: nil, cacheWriteOneHour: 500))
        XCTAssertEqual(cost, 0.0081, accuracy: 0.000_000_1)
    }
}
