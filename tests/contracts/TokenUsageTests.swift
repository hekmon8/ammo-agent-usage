import Foundation
import XCTest
@testable import QuotaCore

final class TokenUsageTests: XCTestCase {
    let utc = TimeZone(identifier: "Etc/UTC")!
    func date(_ value: String) -> Date { QuotaRules.date(value)! }
    func snapshot() -> TokenUsageSnapshot {
        TokenUsageSnapshot(sourceDeviceId: "synthetic-mac", sourceEpoch: "epoch-test", sourceSequence: 1,
            capturedAt: "2026-10-02T03:00:00Z", timeZoneIdentifier: utc.identifier, retainedFromDay: "2026-01-01",
            sources: [TokenUsageSource(agent: .claudeCode, status: .available), TokenUsageSource(agent: .codex, status: .unavailable)],
            buckets: [TokenUsageBucket(day: "2026-10-01", agent: .claudeCode,
                tokens: TokenUsageCounts(nonCachedInput: 100, cacheRead: 200, cacheWrite: 30, output: 40))])
    }
    func testNaturalWeekIsMondayNotTrailingSevenDays() {
        let anchor = date("2026-10-02T03:00:00Z")
        let week = TokenUsageCalendar.interval(.week, anchor: anchor, in: utc)
        let rolling = TokenUsageCalendar.interval(.last7Days, anchor: anchor, in: utc)
        XCTAssertEqual(TokenUsageCalendar.day(week.start, in: utc), "2026-09-28")
        XCTAssertEqual(TokenUsageCalendar.day(week.end, in: utc), "2026-10-05")
        XCTAssertEqual(TokenUsageCalendar.day(rolling.start, in: utc), "2026-09-26")
        XCTAssertEqual(TokenUsageCalendar.day(rolling.end, in: utc), "2026-10-03")
    }
    func testCalendarDSTAndMonthBoundaries() {
        let zone = TimeZone(identifier: "America/New_York")!
        let day = TokenUsageCalendar.interval(.day, anchor: date("2026-03-08T18:00:00Z"), in: zone)
        XCTAssertEqual(day.duration, 23 * 3600)
        let week = TokenUsageCalendar.interval(.week, anchor: date("2026-03-08T18:00:00Z"), in: zone)
        XCTAssertEqual(week.duration, 167 * 3600)
        let month = TokenUsageCalendar.interval(.month, anchor: date("2026-02-28T23:00:00Z"), in: utc)
        XCTAssertEqual(TokenUsageCalendar.day(month.end, in: utc), "2026-03-01")
        XCTAssertEqual(TokenUsageCalendar.day(date("2026-10-01T18:00:00Z"), in: TimeZone(identifier: "Asia/Shanghai")!), "2026-10-02")
        XCTAssertNil(TokenUsageCalendar.date("2026-02-30", in: utc))
    }
    func testUnknownIsNotZeroAndNoMultiSourceSnapshotSumming() {
        let value = snapshot(), anchor = date("2026-10-02T03:00:00Z")
        let summary = TokenUsageSummary.make(snapshot: value, period: .week, anchor: anchor, timeZone: utc)
        XCTAssertEqual(summary.total?.total, 370)
        XCTAssertNil(summary.byAgent[.codex])
        XCTAssertTrue(summary.isPartial)
        XCTAssertNil(TokenUsageSummary.make(snapshot: nil, period: .week, anchor: anchor, timeZone: utc).total)
        XCTAssertNil(TokenUsageSummary.make(snapshot: value, period: .week, anchor: anchor,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!).total)
        XCTAssertNil(TokenUsageSummary.make(snapshot: value, period: .month,
            anchor: date("2025-12-15T00:00:00Z"), timeZone: utc).total)
        XCTAssertEqual(TokenUsageSummary.make(snapshot: value, period: .day, anchor: anchor, timeZone: utc).total?.total, 0)
        let rebase = value.rebased(deviceID: "other-mac", epoch: "other-epoch", sequence: 2)
        XCTAssertEqual(rebase.buckets, value.buckets)
        XCTAssertEqual(TokenUsageSummary.make(snapshot: rebase, period: .week, anchor: anchor, timeZone: utc).total?.total, 370)
    }
    func testCachedObservationBeforePeriodCannotInventZero() {
        let summary = TokenUsageSummary.make(snapshot: snapshot(), period: .day,
            anchor: date("2026-10-03T01:00:00Z"), timeZone: utc)
        XCTAssertNil(summary.total)
        XCTAssertTrue(summary.byAgent.isEmpty)
    }
    func testStrictUsageCodecAndLegacySeparation() throws {
        let bytes = try TokenUsageSnapshotCodec.encode(snapshot())
        XCTAssertEqual(try TokenUsageSnapshotCodec.decode(bytes).buckets, snapshot().buckets)
        XCTAssertThrowsError(try SnapshotCodec.decode(bytes))
        let base = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for edit: ([String: Any]) -> [String: Any] in [
            { var o = $0; o["projectPath"] = "/private/project"; return o },
            { var o = $0; o["schemaVersion"] = "2.0.0"; return o },
            { var o = $0; o["sourceSequence"] = true; return o },
            { var o = $0; o["timeZoneIdentifier"] = "invalid/timezone"; return o },
            { var o = $0; o["retainedFromDay"] = "2026-02-30"; return o },
            { var o = $0; o["buckets"] = ($0["buckets"] as! [Any]) + ($0["buckets"] as! [Any]); return o }
        ] { XCTAssertThrowsError(try TokenUsageSnapshotCodec.decode(JSONSerialization.data(withJSONObject: edit(base)))) }
        XCTAssertThrowsError(try TokenUsageSnapshotCodec.decode(Data(repeating: 32, count: TokenUsageSnapshotCodec.maxBytes + 1)))
        let negative = TokenUsageCounts(nonCachedInput: -1)
        XCTAssertFalse(negative.isValid)
        XCTAssertNil(TokenUsageCounts(nonCachedInput: 2_251_799_813_685_247).adding(TokenUsageCounts(nonCachedInput: 1)))
    }
}
