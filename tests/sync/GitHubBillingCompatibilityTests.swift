import Foundation
import XCTest
import QuotaCore
@testable import QuotaSync

final class GitHubBillingCompatibilityTests: XCTestCase {
    func testUnknownExpenseSyncsAsNullAndDoesNotBecomeZeroOrExhausted() throws {
        let now = QuotaRules.date("2026-10-08T00:00:00Z")!
        let unknown = QuotaWindow.providerValue(id: "github-synthetic-window", providerID: "github-actions",
            accountID: "native-synthetic-hash", alias: "PRIVATE_LOCAL_ALIAS", key: "cost-spend", unit: .money,
            currency: "USD", availability: .unavailable, remainingBps: nil, amount: nil, limit: nil,
            quality: .unknown, source: .officialAPI, outcome: .error, observedAt: now, staleAt: now,
            windowKind: .calendar, duration: nil, resetsAt: nil, startsAt: QuotaRules.date("2026-10-01T00:00:00Z"),
            periodID: "github-actions-user-2026-10")
        let snapshot = try Snapshot.make(windows: [unknown], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now)
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        let window = try XCTUnwrap(decoded.windows.first)
        XCTAssertEqual(QuotaPresentation(window: window, now: now).state, .unavailable)
        XCTAssertNil(window.amount); XCTAssertNil(window.limit); XCTAssertNil(window.remainingBps)
        XCTAssertEqual(window.quality, .unknown); XCTAssertEqual(window.fetchOutcome, .error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteMCPProjection.encode(snapshot, sourceEpoch: "synthetic")) as? [String: Any])
        let projected = try XCTUnwrap((object["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(projected["availability"] as? String, "unavailable")
        for field in ["amount", "limit", "remainingBps", "resetsAt"] { XCTAssertTrue(projected[field] is NSNull) }
    }
    func testExpenseUsesExistingStrictSnapshotAndRedactedMCPShape() throws {
        let now = QuotaRules.date("2026-10-07T12:00:00Z")!
        let window = QuotaWindow.providerValue(id: "github-synthetic-window", providerID: "github-actions",
            accountID: "native-synthetic-hash", alias: "PRIVATE_LOCAL_ALIAS", key: "cost-spend", unit: .money,
            currency: "USD", remainingBps: nil, amount: "8", limit: nil, quality: .reported,
            source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
            windowKind: .calendar, duration: nil, resetsAt: nil,
            startsAt: QuotaRules.date("2026-10-01T00:00:00Z"), periodID: "github-actions-user-2026-10")
        let snapshot = try Snapshot.make(windows: [window], deviceID: "test", epoch: "test", sequence: 1, capturedAt: now)
        let encoded = try SnapshotCodec.encode(snapshot)
        let decoded = try SnapshotCodec.decode(encoded)
        XCTAssertEqual(decoded.windows.first?.quotaKey, "cost-spend")
        XCTAssertEqual(decoded.windows.first?.window.periodId, "github-actions-user-2026-10")
        XCTAssertNil(decoded.windows.first?.remainingBps)
        XCTAssertNil(decoded.windows.first?.limit)
        XCTAssertNil(decoded.windows.first?.window.resetsAt)
        let projection = try RemoteMCPProjection.encode(snapshot, sourceEpoch: "test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: projection) as? [String: Any])
        let value = try XCTUnwrap((object["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(value.keys), Set(["id", "providerId", "unit", "currency", "quotaKey", "availability",
            "remainingBps", "amount", "limit", "quality", "fetchOutcome", "observedAt", "staleAt", "resetsAt"]))
        XCTAssertEqual(value["amount"] as? String, "8")
        XCTAssertEqual(value["quotaKey"] as? String, "cost-spend")
        for field in ["limit", "remainingBps", "resetsAt"] { XCTAssertTrue(value[field] is NSNull) }
        let text = String(decoding: projection, as: UTF8.self)
        for forbidden in ["PRIVATE_LOCAL_ALIAS", "native-synthetic-hash", "github-synthetic-window",
                          "budgets", "budget_amount", "prevent_further_usage", "alert_recipients", "Authorization", "token"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }
}
