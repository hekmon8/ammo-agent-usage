import XCTest
import QuotaCore
import QuotaDesign

final class CompactMetricToneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func reading(amount: String = "30", ratio: Int? = nil, key: String = "balance",
                         outcome: FetchOutcome = .ok, stale: TimeInterval = 600,
                         locked: Bool = false) -> QuotaPresentation {
        let window = QuotaWindow.providerValue(id: "metric", providerID: "fal", accountID: "sample", alias: "Synthetic",
            key: key, unit: ratio == nil ? .money : .percent, currency: ratio == nil ? "USD" : nil,
            remainingBps: ratio, amount: ratio == nil ? amount : nil, limit: nil,
            quality: .reported, source: .officialAPI, outcome: outcome,
            observedAt: now, staleAt: now.addingTimeInterval(stale),
            windowKind: .unknown, duration: nil, resetsAt: nil)
        return QuotaPresentation(window: window, now: now, locked: locked)
    }
    func testZeroBalanceIsCriticalWithoutConfiguredRuleButZeroSpendIsNormal() {
        XCTAssertEqual(CompactMetricTone(reading(amount: "0")), .critical)
        XCTAssertEqual(CompactMetricTone(reading(amount: "0", key: "cost-spend")), .normal)
    }
    func testUnavailableAndHistoricalReadingsStayMutedEvenWithCriticalRule() {
        XCTAssertEqual(CompactMetricTone(reading(locked: true), severity: .critical), .muted)
        XCTAssertEqual(CompactMetricTone(reading(outcome: .error), severity: .critical), .muted)
        XCTAssertEqual(CompactMetricTone(reading(stale: -1), severity: .critical), .muted)
    }
    func testReferenceThresholdsAndRuleSeverity() {
        XCTAssertEqual(CompactMetricTone(reading(ratio: 5100)), .normal)
        XCTAssertEqual(CompactMetricTone(reading(ratio: 5000)), .warning)
        XCTAssertEqual(CompactMetricTone(reading(ratio: 2000)), .warning)
        XCTAssertEqual(CompactMetricTone(reading(ratio: 1999)), .critical)
        XCTAssertEqual(CompactMetricTone(reading(ratio: 8000), severity: .critical), .critical)
    }
}
