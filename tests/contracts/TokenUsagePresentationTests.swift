import Foundation
import XCTest
import QuotaCore
import QuotaDesign

final class TokenUsagePresentationTests: XCTestCase {
    func testUnknownIsNotRenderedAsZero() {
        XCTAssertEqual(TokenUsageText.number(nil), "—")
        XCTAssertEqual(TokenUsageText.number(0), "0")
    }

    func testCoverageReflectsReadableSourcesRatherThanAccountScope() {
        func sources(_ states: [TokenUsageSource.Status]) -> [TokenUsageSource] {
            states.enumerated().map { .init(agent: $0.offset == 0 ? .codex : .claudeCode, status: $0.element) }
        }
        for states in [[], [.unavailable], [.unavailable, .disabled]] as [[TokenUsageSource.Status]] {
            XCTAssertEqual(TokenUsageText.coverageKey(sources(states)), "tokenUsage.source.unavailable")
        }
        XCTAssertEqual(TokenUsageText.coverageKey(sources([.disabled, .disabled])), "tokenUsage.source.disabled")
        for states in [[.available], [.available, .available], [.available, .unavailable]] as [[TokenUsageSource.Status]] {
            XCTAssertEqual(TokenUsageText.coverageKey(sources(states)), "tokenUsage.coverage.readable")
        }
        XCTAssertEqual(TokenUsageText.coverageKey(sources([.available, .partial])), "tokenUsage.coverage.partial")
    }
    func testEmptyPeriodIsDistinctFromRecordedZero() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let anchor = try XCTUnwrap(QuotaRules.date("2026-10-02T12:00:00Z"))
        func summary(_ buckets: [TokenUsageBucket]) -> TokenUsageSummary {
            let snapshot = TokenUsageSnapshot(sourceDeviceId: "synthetic", sourceEpoch: "synthetic", sourceSequence: 1,
                capturedAt: "2026-10-02T12:00:00Z", timeZoneIdentifier: zone.identifier, retainedFromDay: "2026-01-01",
                sources: [.init(agent: .codex, status: .available)], buckets: buckets)
            return TokenUsageSummary.make(snapshot: snapshot, period: .day, anchor: anchor, timeZone: zone)
        }
        XCTAssertEqual(TokenUsageText.agentValue(.codex, summary: summary([])), L("tokenUsage.noRecordedEvents"))
        XCTAssertEqual(TokenUsageText.agentValue(.codex, summary: summary([.init(day: "2026-10-02", agent: .codex, tokens: .zero)])), "0")
        XCTAssertEqual(TokenUsageText.agentValue(.claudeCode, summary: summary([])), "—")
        XCTAssertFalse(TokenUsageText.hasRecords(.codex, summary: summary([])))
        XCTAssertTrue(TokenUsageText.hasRecords(.codex, summary: summary([.init(day: "2026-10-02", agent: .codex, tokens: .zero)])))
        XCTAssertEqual(TokenUsageText.periodStatus(.codex, source: .init(agent: .codex, status: .available), summary: summary([])), L("tokenUsage.noRecordedEvents"))
    }

    func testReceiptScopeKeepsLocalAndHistoricalMeaningInOneLabel() {
        let previousLanguage = L10n.currentSetting
        defer { L10n.setLanguage(previousLanguage) }
        for language in [QuotaLanguage.simplifiedChinese, .english] {
            L10n.setLanguage(language)
            let current = TokenUsageText.receiptScope(stale: false)
            let cached = TokenUsageText.receiptScope(stale: true)
            XCTAssertEqual(current, L("tokenUsage.receipt.scope"))
            XCTAssertTrue(cached.contains(L("tokenUsage.receipt.cached")))
            for label in [current, cached] {
                XCTAssertTrue(label.contains(L("tokenUsage.receipt.scope")))
                XCTAssertFalse(label.contains("\n"))
                XCTAssertFalse(label.contains("tokenUsage."))
            }
        }
    }

    func testSingleDayLabelUsesCollectorTimeZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let anchor = try XCTUnwrap(QuotaRules.date("2026-10-01T12:00:00Z"))
        let summary = TokenUsageSummary.make(snapshot: nil, period: .day, anchor: anchor, timeZone: zone)
        XCTAssertEqual(TokenUsageText.range(summary, timeZone: zone), TokenUsageText.date(summary.start, timeZone: zone))
    }

    func testDayNavigationUsesCalendarArithmeticAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let before = try XCTUnwrap(QuotaRules.date("2026-03-07T20:00:00Z"))
        let after = TokenUsageText.moved(before, period: .day, offset: 1, timeZone: zone)
        XCTAssertEqual(after, QuotaRules.date("2026-03-08T19:00:00Z"))
        XCTAssertEqual(TokenUsageText.moved(after, period: .day, offset: -1, timeZone: zone), before)
    }

    func testNaturalWeekAndRollingWeekStayDistinct() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let anchor = try XCTUnwrap(QuotaRules.date("2026-10-02T12:00:00Z"))
        let natural = TokenUsageSummary.make(snapshot: nil, period: .week, anchor: anchor, timeZone: zone)
        let rolling = TokenUsageSummary.make(snapshot: nil, period: .last7Days, anchor: anchor, timeZone: zone)
        XCTAssertNotEqual(natural.start, rolling.start)
        XCTAssertEqual(TokenUsageText.calendar(zone).component(.weekday, from: natural.start), 2)
    }

    func testReceiptProjectionDoesNotRetainIdentityOrDiagnostics() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let snapshot = TokenUsageSnapshot(
            sourceDeviceId: "private-device-marker", sourceEpoch: "private-epoch-marker", sourceSequence: 1,
            capturedAt: "2026-10-02T12:00:00Z", timeZoneIdentifier: zone.identifier, retainedFromDay: "2026-01-01",
            sources: [.init(agent: .codex, status: .partial, diagnostic: "private_diagnostic_marker")],
            buckets: [.init(day: "2026-10-02", agent: .codex, tokens: .init(nonCachedInput: 50, cacheRead: 20, output: 10))]
        )
        let summary = TokenUsageSummary.make(snapshot: snapshot, period: .day,
                                             anchor: try XCTUnwrap(QuotaRules.date(snapshot.capturedAt)),
                                             timeZone: zone)
        let receipt = TokenUsageReceiptData(snapshot: snapshot, summary: summary, period: .day, stale: true)
        let fields = Set(Mirror(reflecting: receipt).children.compactMap(\.label))
        XCTAssertEqual(fields, ["start", "end", "total", "byAgent", "daily", "isPartial", "timeZone", "capturedAt", "period", "stale"])
        let description = String(reflecting: receipt)
        for privateValue in ["private-device-marker", "private-epoch-marker", "private_diagnostic_marker"] {
            XCTAssertFalse(description.contains(privateValue))
        }
        XCTAssertEqual(receipt.total?.total, 80)
        XCTAssertTrue(receipt.stale)
        XCTAssertTrue(receipt.isPartial)
    }
}
