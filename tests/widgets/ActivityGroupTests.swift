import XCTest
import Foundation
import QuotaCore
import QuotaWidgets

final class ActivityGroupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_572_460)
    private func window(_ id: String, provider: String = "codex", account: String = "private-account", bps: Int = 6800, duration: Int = 18000) -> QuotaWindow {
        .reported(id: id, providerID: provider, accountID: account, alias: "Same private alias", key: id,
                  remainingBps: bps, observedAt: now, staleAt: now.addingTimeInterval(600),
                  duration: duration, resetsAt: now.addingTimeInterval(Double(duration)), source: .userDefined)
    }
    private func snapshot(_ rows: [QuotaWindow], sequence: Int64 = 7) throws -> Snapshot {
        try .make(windows: rows, deviceID: "mac", epoch: "epoch", sequence: sequence, capturedAt: now)
    }
    func testTwoPeriodsOrPlatformsKeepIndependentValuesInSelectedOrder() throws {
        for provider in ["codex", "glm"] {
            let source = try snapshot([window("first", bps: 6800), window("second", provider: provider, bps: 4200, duration: 604800)])
            let result = try ActivityGroupProjection(snapshot: source, windowIDs: ["second", "first"], now: now)
            XCTAssertEqual(result.content.rows.map(\.windowID), ["second", "first"])
            XCTAssertEqual(result.content.rows.map(\.remainingBps), [4200, 6800])
            XCTAssertNotEqual(result.content.rows[0].resetsAt, result.content.rows[1].resetsAt)
            XCTAssertTrue(result.supportsRemote)
            XCTAssertEqual(source.windows.count, 2)
        }
    }
    func testSameAliasAccountsAreLocallyDistinguishedWithoutLeakingIdentity() throws {
        let projection = try ActivityGroupProjection(snapshot: snapshot([window("a", account: "secret-a"), window("b", account: "secret-b")]), windowIDs: ["b", "a"], now: now)
        XCTAssertEqual(projection.descriptors.map(\.accountOrdinal), [1, 2])
        let bytes = try JSONEncoder().encode(projection.content)
        let labels = try JSONEncoder().encode(projection.descriptors)
        for text in [String(decoding: bytes, as: UTF8.self), String(decoding: labels, as: UTF8.self)] {
            XCTAssertFalse(text.contains("secret-")); XCTAssertFalse(text.contains("private alias"))
        }
    }
    func testMissingRowDoesNotRemoveOrRenameAnotherRowAndMakesImmediateStaleDate() throws {
        let first = try ActivityGroupProjection(snapshot: snapshot([window("a"), window("b", provider: "glm")]), windowIDs: ["a", "b"], now: now)
        let next = try ActivityGroupProjection(snapshot: snapshot([window("b", provider: "glm", bps: 5100)], sequence: 8), windowIDs: ["a", "b"], previous: first.descriptors, now: now)
        XCTAssertEqual(next.content.rows[0].displayState, "unavailable")
        XCTAssertNil(next.content.rows[0].remainingBps)
        XCTAssertEqual(next.descriptors[0], first.descriptors[0])
        XCTAssertEqual(next.content.rows[1].remainingBps, 5100)
        XCTAssertEqual(next.content.staleDate(endsAt: Int64(now.addingTimeInterval(28000).timeIntervalSince1970), now: now), now)
        XCTAssertFalse(next.supportsRemote)
    }
    func testFreshnessRemainsIndependentWhenGroupEarliestDateHasExpired() throws {
        let t = Int64(now.timeIntervalSince1970)
        let old = ActivityGroupRow(windowID: "old", remainingBps: 6800, displayState: "fresh", observedAt: t-300, staleAt: t-1, resetsAt: t+900, sequence: 8)
        let fresh = ActivityGroupRow(windowID: "fresh", remainingBps: 4200, displayState: "fresh", observedAt: t, staleAt: t+600, resetsAt: t+900, sequence: 2)
        let content = try ActivityGroupContent(bundleRevision: 12, rows: [old, fresh])
        XCTAssertEqual(content.staleDate(endsAt: t+28000, now: now), Date(timeIntervalSince1970: Double(t-1)))
        let a = ActivityDisplaySemantics(remainingBps: old.remainingBps, displayState: old.displayState, observedAt: old.observedAt, staleAt: old.staleAt, resetsAt: old.resetsAt, endsAt: t+28000, now: t, systemIsStale: true)
        let b = ActivityDisplaySemantics(remainingBps: fresh.remainingBps, displayState: fresh.displayState, observedAt: fresh.observedAt, staleAt: fresh.staleAt, resetsAt: fresh.resetsAt, endsAt: t+28000, now: t, systemIsStale: false)
        XCTAssertNotEqual(a.visualState, b.visualState)
        XCTAssertEqual(b.remainingBps, 4200)
        XCTAssertEqual(content.rows.map(\.sequence), [8, 2])
    }
    func testWireNullsSizeAndContractExampleDecode() throws {
        let null = ActivityGroupRow(windowID: String(repeating: "a", count: 80), remainingBps: nil, displayState: "unavailable", observedAt: nil, staleAt: nil, resetsAt: nil, sequence: 0)
        let value = try ActivityGroupContent(bundleRevision: 1, rows: [null])
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        for key in ["remainingBps", "observedAt", "staleAt", "resetsAt"] { XCTAssertTrue(row[key] is NSNull) }
        XCTAssertEqual(try JSONDecoder().decode(ActivityGroupContent.self, from: data), value)
        var missing = row; missing.removeValue(forKey: "staleAt")
        XCTAssertThrowsError(try JSONDecoder().decode(ActivityGroupContent.self, from: JSONSerialization.data(withJSONObject: ["version":2,"bundleRevision":1,"rows":[missing]])))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let example = try Data(contentsOf: root.appendingPathComponent("contracts/examples/live-activity-v2-content.example.json"))
        XCTAssertEqual(try JSONDecoder().decode(ActivityGroupContent.self, from: example).rows.count, 2)
        let labels = ["a", "b"].map { ActivityGroupDescriptor(windowID: String(repeating: $0, count: 80), providerID: String(repeating: "中", count: 80), title: String(repeating: "界", count: 80), accountOrdinal: 2) }
        let labelBytes = try JSONEncoder().encode(labels)
        XCTAssertLessThan(data.count * 2 + labelBytes.count + 1000, 4096)
        let complex = ActivityGroupDescriptor(windowID: "a", providerID: "codex", title: "a" + String(repeating: "\u{0301}", count: 800))
        XCTAssertLessThanOrEqual(complex.title.utf8.count, 144)
    }
    func testInvalidDuplicatesAndEstimatedQualityCannotBecomeRemoteGroup() throws {
        let source = try snapshot([window("a"), window("b")])
        XCTAssertThrowsError(try ActivityGroupProjection(snapshot: source, windowIDs: ["a", "a"], now: now))
        XCTAssertThrowsError(try ActivityGroupProjection(snapshot: source, windowIDs: ["a", "b", "c"], now: now))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window("b"))) as? [String: Any])
        raw["quality"] = "estimated"
        let estimated = try JSONDecoder().decode(QuotaWindow.self, from: JSONSerialization.data(withJSONObject: raw))
        let projection = try ActivityGroupProjection(snapshot: snapshot([window("a"), estimated]), windowIDs: ["a", "b"], now: now)
        XCTAssertFalse(projection.supportsRemote)
        XCTAssertNotEqual(projection.descriptors[1].title, estimated.shortDisplayName)
    }
}
