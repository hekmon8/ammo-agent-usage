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

    func testCurrentEligibilityDoesNotDiscardRetainedData() throws {
        let now = QuotaRules.date("2026-09-05T01:42:00Z")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cases: [(String, FetchOutcome, Availability, Int, Int?, String)] = [
            ("error", .error, .available, -60, nil, "stale"),
            ("throttled", .throttled, .available, -60, nil, "stale"),
            ("disabled", .disabled, .unlimited, -60, nil, "stale"),
            ("auth", .authRequired, .available, -60, nil, "authRequired"),
            ("unavailable", .ok, .unavailable, -60, nil, "unavailable"),
            ("past-reset", .ok, .available, -60, 0, "resetPending"),
            ("post-reset", .ok, .available, -30, -30, "fresh"),
            ("current", .ok, .available, -60, 60, "fresh")
        ]
        let windows = cases.map { id, outcome, availability, observed, reset, _ in
            QuotaWindow.reported(id: id, providerID: "codex", accountID: "private", alias: "Private Account",
                key: id, remainingBps: availability == .available ? 6_800 : nil,
                observedAt: now.addingTimeInterval(Double(observed)), staleAt: now.addingTimeInterval(600),
                duration: 3_600, resetsAt: reset.map { now.addingTimeInterval(Double($0)) }, source: .localRPC,
                availability: availability).withOutcome(outcome)
                .withHistory(availability == .available ? [.observation(at: "2026-09-05T01:41:00Z", remainingBps: 6_800, segmentID: "test")] : [])
        }
        let snapshot = try Snapshot.make(windows: windows, deviceID: "mac", epoch: "test", sequence: 1, capturedAt: now)
        try PrivateFile.write(SnapshotCodec.encode(snapshot), to: directory.appendingPathComponent("latest-public.json"))
        let query = QuotaQuery(directory: directory, now: { now })

        XCTAssertEqual(try query.list(includeStale: false, requireFresh: true).windows.map(\.id), ["post-reset", "current"])
        XCTAssertEqual(try query.health().freshWindowCount, 2)
        XCTAssertEqual(try query.health().staleWindowCount, 6)
        XCTAssertThrowsError(try query.status(requireFresh: true)) { XCTAssertEqual($0 as? QueryError, .noFreshData) }
        for (id, outcome, _, _, _, freshness) in cases {
            let window = try query.get(windowId: id)
            XCTAssertEqual(window.freshness, freshness, id)
            XCTAssertEqual(window.fetchOutcome, outcome.rawValue)
            if freshness != "fresh" {
                XCTAssertThrowsError(try query.get(windowId: id, requireFresh: true)) { XCTAssertEqual($0 as? QueryError, .noFreshData) }
                XCTAssertThrowsError(try query.history(windowId: id, range: 600, requireFresh: true)) { XCTAssertEqual($0 as? QueryError, .noFreshData) }
            }
        }
        let retained = try query.history(windowId: "error", range: 600)
        XCTAssertEqual(retained.window.value.remainingBps, 6_800)
        XCTAssertEqual(retained.window.staleAt, "2026-09-05T01:52:00Z")
        XCTAssertEqual(retained.points.map(\.remainingBps), [6_800])
        // Local projections name the account so several logins stay distinguishable; the remote projection does not.
        XCTAssertEqual(retained.window.accountId, "private")
        XCTAssertEqual(retained.window.accountAlias, "Private Account")
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

    func testAccountsAreExposedAndFilterable() throws {
        let directory = try makeDirectory(fixture: "13-two-accounts.json")
        let query = QuotaQuery(directory: directory, now: { QuotaRules.date("2026-09-05T01:42:00Z")! })

        let codex = try query.list(providerId: "codex").windows
        XCTAssertEqual(codex.map(\.id), ["codex-account_work-primary", "codex-account_work-secondary", "codex-account_personal-primary"])
        XCTAssertEqual(codex.map(\.accountId), ["account_work", "account_work", "account_personal"])
        XCTAssertEqual(codex.map(\.accountAlias), ["工作账户", "工作账户", "个人账户"])
        XCTAssertEqual(try query.list(providerId: "codex", accountId: "account_personal").windows.map(\.id), ["codex-account_personal-primary"])
        XCTAssertTrue(try query.list(accountId: "missing").windows.isEmpty)
        let providers = try query.providers()
        XCTAssertEqual(providers.providerIds, ["codex"])
        XCTAssertEqual(providers.accounts.map(\.accountId), ["account_work", "account_personal"])
        XCTAssertEqual(providers.accounts.map(\.accountAlias), ["工作账户", "个人账户"])
        XCTAssertEqual(providers.accounts.map(\.windowCount), [2, 1])
    }

    func testLegacyWindowIdResolvesOnlyWhileItNamesOneAccount() throws {
        let now: @Sendable () -> Date = { QuotaRules.date("2026-09-05T01:42:00Z")! }
        let single = QuotaQuery(directory: try makeDirectory(fixture: "01-fresh.json"), now: now)
        XCTAssertEqual(try single.get(windowId: "codex-primary").id, "codex-primary")

        let query = QuotaQuery(directory: try makeDirectory(fixture: "13-two-accounts.json"), now: now)
        XCTAssertEqual(try query.get(windowId: "codex-account_personal-primary").value.remainingBps, 9100)
        // The pre-account `provider-quotaKey` form still resolves while it names one window.
        XCTAssertEqual(try query.get(windowId: "codex-secondary").id, "codex-account_work-secondary")
        XCTAssertThrowsError(try query.get(windowId: "codex-primary")) { XCTAssertEqual($0 as? QueryError, .ambiguousWindow) }
        XCTAssertThrowsError(try query.history(windowId: "codex-primary", range: 3600)) { XCTAssertEqual($0 as? QueryError, .ambiguousWindow) }
        XCTAssertThrowsError(try query.get(windowId: "codex-missing")) { XCTAssertEqual($0 as? QueryError, .windowNotFound) }
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
