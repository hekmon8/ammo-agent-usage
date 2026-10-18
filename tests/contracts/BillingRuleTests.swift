import XCTest
@testable import QuotaCore

final class BillingRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func window(_ amount: String, key: String = "balance", offset: TimeInterval = 0,
                        stale: TimeInterval = 600, outcome: FetchOutcome = .ok, currency: String = "USD", period: String? = nil, start: TimeInterval? = nil) -> QuotaWindow {
        .providerValue(id: "wallet", providerID: "fal", accountID: "account", alias: "Synthetic",
            key: key, unit: .money, currency: currency, remainingBps: nil, amount: amount, limit: nil,
            quality: .reported, source: .officialAPI, outcome: outcome,
            observedAt: now.addingTimeInterval(offset), staleAt: now.addingTimeInterval(stale),
            windowKind: .unknown, duration: nil, resetsAt: nil, startsAt: start.map { now.addingTimeInterval($0) }, periodID: period)
    }
    private var low: BillingRule { .init(windowID: "wallet", kind: .lowBalance, currency: "USD", warning: "10", critical: "3") }

    func testBalanceAndConsumptionHaveOppositeDirections() {
        XCTAssertEqual(low.severity(for: 3), .critical)
        XCTAssertEqual(low.severity(for: 10), .warning)
        XCTAssertEqual(low.severity(for: 11), .normal)
        let spend = BillingRule(windowID: "wallet", kind: .budget, currency: "USD", warning: "80", critical: "100")
        XCTAssertEqual(spend.severity(for: 0), .normal)
        XCTAssertEqual(spend.severity(for: 80), .warning)
        XCTAssertEqual(spend.severity(for: 120), .critical)
        XCTAssertNil(low.value(for: window("0", key: "cost-spend"), now: now))
        XCTAssertNil(spend.value(for: window("120"), now: now))
    }
    func testFailureStaleFutureCurrencyAndDisabledNeverAlert() {
        var ledger = BillingAlertLedger()
        for w in [window("0", stale: -1), window("0", outcome: .error), window("0", outcome: .disabled),
                  window("0", outcome: .authRequired), window("0", offset: 121), window("0", currency: "EUR")] {
            XCTAssertNil(ledger.evaluate(low, window: w, now: now))
        }
        var disabled = low; disabled.enabled = false
        XCTAssertNil(ledger.evaluate(disabled, window: window("0"), now: now))
        XCTAssertTrue(ledger.entries.isEmpty)
    }
    func testDedupeEscalationRecoveryAndPersistence() throws {
        var ledger = BillingAlertLedger()
        XCTAssertEqual(ledger.evaluate(low, window: window("8"), now: now), .warning)
        XCTAssertNil(ledger.evaluate(low, window: window("8"), now: now))
        ledger = try JSONDecoder().decode(BillingAlertLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertNil(ledger.evaluate(low, window: window("7", offset: 1), now: now.addingTimeInterval(1)))
        XCTAssertEqual(ledger.evaluate(low, window: window("2", offset: 2), now: now.addingTimeInterval(2)), .critical)
        XCTAssertNil(ledger.evaluate(low, window: window("40", offset: 3, outcome: .error), now: now.addingTimeInterval(3)))
        XCTAssertNil(ledger.evaluate(low, window: window("2", offset: 4), now: now.addingTimeInterval(4)))
        XCTAssertNil(ledger.evaluate(low, window: window("40", offset: 5), now: now.addingTimeInterval(5)))
        XCTAssertEqual(ledger.evaluate(low, window: window("8", offset: 6), now: now.addingTimeInterval(6)), .warning)
    }
    func testNewPeriodRearmsButOlderObservationDoesNot() {
        var ledger = BillingAlertLedger()
        let budget = BillingRule(windowID: "wallet", kind: .budget, currency: "USD", warning: "80", critical: "100")
        XCTAssertEqual(ledger.evaluate(budget, window: window("101", key: "cost-spend", period: "one", start: -200), now: now), .critical)
        XCTAssertEqual(ledger.evaluate(budget, window: window("101", key: "cost-spend", offset: 1, period: "two", start: -100), now: now.addingTimeInterval(1)), .critical)
        XCTAssertNil(ledger.evaluate(budget, window: window("0", key: "cost-spend", period: "one", start: -200), now: now.addingTimeInterval(2)))
        XCTAssertNil(ledger.evaluate(budget, window: window("0", key: "cost-spend", offset: 2, period: "one", start: -200), now: now.addingTimeInterval(2)))
        XCTAssertEqual(ledger.entries["wallet"]?.period, "two")
        XCTAssertNil(ledger.evaluate(budget, window: window("101", key: "cost-spend", offset: 3, period: "two", start: -100), now: now.addingTimeInterval(3)))
    }
    func testStrictThresholdValidationAndMoneyCategories() {
        for text in ["NaN", "-1", "1e9", "1bad", "", "1,2"] {
            XCTAssertNil(BillingRule.number(text))
        }
        XCTAssertFalse(BillingRule(windowID: "wallet", kind: .budget, currency: "USD", warning: "100", critical: "80").isValid)
        XCTAssertEqual(window("0").category, .balance)
        XCTAssertEqual(window("0", key: "cost-spend").category, .spend)
        XCTAssertEqual(window("0", key: "free-balance").category, .allowance)
        XCTAssertEqual(QuotaRules.state(window("0", key: "cost-spend"), now: now), .fresh)
    }
}
