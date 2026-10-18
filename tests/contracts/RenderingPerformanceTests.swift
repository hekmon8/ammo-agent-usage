import Foundation
import XCTest
import QuotaCore
import QuotaDesign

final class RenderingPerformanceTests: XCTestCase {
    func testCachedParserPreservesFormatsAndConcurrentReads() {
        let inputs = ["2026-09-06T06:00:00Z", "2026-09-06T06:00:00.125Z", "2026-09-06T08:00:00+02:00", "invalid"]
        let expected = inputs.map { value -> Date? in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let slot = index % inputs.count
            XCTAssertEqual(QuotaRules.date(inputs[slot]), expected[slot])
        }
    }

    func testRepeatedTimestampBenchmark() {
        let input = "2026-09-06T06:00:00Z"
        let start = Date()
        for _ in 0..<3000 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            _ = formatter.date(from: input) ?? ISO8601DateFormatter().date(from: input)
        }
        let oldDuration = Date().timeIntervalSince(start)
        let cachedStart = Date()
        for _ in 0..<3000 { XCTAssertNotNil(QuotaRules.date(input)) }
        let cachedDuration = Date().timeIntervalSince(cachedStart)
        XCTAssertLessThan(cachedDuration, oldDuration / 5, "Repeated rendering must reuse parsed timestamps")
        print("DATE_BENCHMARK 3000 timestamps: original=\(oldDuration)s cached=\(cachedDuration)s")
    }

    func testIslandSelectionHonorsPinsAndFallsBackWithoutDuplicates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let snapshot = try SnapshotCodec.decode(Data(contentsOf: root.appendingPathComponent("contracts/fixtures/08-multiple-windows.json")))
        let values = snapshot.windows.map { QuotaPresentation(window: $0, now: Date()) }
        XCTAssertGreaterThan(values.count, 1)
        let last = values.last!.window.id
        let first = values.first!.window.id
        let pinned = IslandSummarySelection.select(values, leftID: last, rightID: first)
        XCTAssertEqual(pinned.left?.window.id, last)
        XCTAssertEqual(pinned.right?.window.id, first)
        let duplicate = IslandSummarySelection.select(values, leftID: first, rightID: first)
        XCTAssertNotEqual(duplicate.left?.window.id, duplicate.right?.window.id)
        let missingPins = IslandSummarySelection.select(values, leftID: "removed-left", rightID: "removed-right")
        XCTAssertNil(missingPins.left)
        XCTAssertNil(missingPins.right)
        XCTAssertEqual(IslandSummarySelection.select(values, leftID: "", rightID: last).right?.window.id, last)
        let pinnedSecondCodex = IslandSummarySelection.select(values, leftID: "", rightID: values[1].window.id)
        XCTAssertEqual(pinnedSecondCodex.left?.window.providerId, "claude")
        let empty = IslandSummarySelection.select([], leftID: first, rightID: last)
        XCTAssertNil(empty.left); XCTAssertNil(empty.right)
        let single = IslandSummarySelection.select([values[0]], leftID: "", rightID: "")
        XCTAssertNotNil(single.left); XCTAssertNil(single.right)
        let rightOnly = IslandSummarySelection.select([values[0]], leftID: "", rightID: first)
        XCTAssertNil(rightOnly.left); XCTAssertEqual(rightOnly.right?.window.id, first)
    }
}
