import Foundation
import XCTest
@testable import QuotaCore
@testable import QuotaQuery
@testable import QuotaStore

final class QuotaQueryTests: XCTestCase {
    func testFreshProjectionIncludesRequiredSchedulingSemantics() throws {
        let directory = try makeDirectory(fixture: "01-fresh.json")
        let query = QuotaQuery(directory: directory, now: { QuotaRules.date("2026-09-05T01:42:00Z")! })

        let window = try query.get(windowId: "codex-primary")

        XCTAssertEqual(window.freshness, "fresh")
        XCTAssertEqual(window.availability, "available")
        XCTAssertEqual(window.quality, "reported")
        XCTAssertEqual(window.value.remainingBps, 6800)
        XCTAssertEqual(window.scope, "latest_snapshot")
        XCTAssertEqual(window.observedAt, "2026-09-05T01:41:00Z")
        XCTAssertEqual(window.staleAt, "2026-09-05T01:51:00Z")
    }

    func testProviderFilteringAndStaleExclusionUseTheSameProjection() throws {
        let directory = try makeDirectory(fixture: "03-stale.json")
        let query = QuotaQuery(directory: directory, now: { QuotaRules.date("2026-09-05T02:00:00Z")! })

        XCTAssertTrue(try query.list(providerId: "other").windows.isEmpty)
        XCTAssertTrue(try query.list(providerId: "codex", includeStale: false).windows.isEmpty)
        XCTAssertEqual(try query.list(providerId: "codex").windows.first?.freshness, "stale")
        XCTAssertThrowsError(try query.status(requireFresh: true)) { XCTAssertEqual($0 as? QueryError, .noFreshData) }
    }

    func testHistoryPreservesGapAndDeclaresItsBoundedScope() throws {
        let directory = try makeDirectory(fixture: "10-gap.json")
        let query = QuotaQuery(directory: directory, now: { QuotaRules.date("2026-09-05T01:42:00Z")! })

        let history = try query.history(windowId: "codex-primary", range: 2 * 3600)

        XCTAssertEqual(history.scope, "bounded_snapshot_history")
        XCTAssertTrue(history.limited)
        XCTAssertTrue(history.points.contains(where: \.gap))
        XCTAssertEqual(history.points.first(where: \.gap)?.remainingBps, nil)
    }

    func testUnknownInputKeysAreRejectedBeforeQueryExecution() {
        XCTAssertThrowsError(try QueryArguments.rejectUnknown(["providerId", "writeCommand"], allowed: ["providerId", "includeStale"]))
    }

    private func makeDirectory(fixture name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(name)"))
        try PrivateFile.write(data, to: directory.appendingPathComponent("latest-public.json"))
        return directory
    }
}
