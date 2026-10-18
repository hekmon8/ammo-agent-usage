import XCTest
import QuotaCore
@testable import QuotaProviders

final class PlatformBillingTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
    func testPermissionScopeDeniedIsDistinctFromInvalidCredential() {
        XCTAssertEqual(NativeHTTP.classify(NativeHTTP.Failure.httpStatus(403)), .permissionDenied)
        XCTAssertEqual(NativeHTTP.classify(NativeHTTP.Failure.httpStatus(401)), .authRequired)
    }
    func testFalBalanceAndAccountIdentityAcrossKeys() throws {
        let usage = try FalUsageReader.parse(Data(#"{"username":"team-demo","credits":{"current_balance":24.5,"currency":"USD"}}"#.utf8), now: now)
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "fal", alias: "Demo", source: .officialAPI)
        XCTAssertEqual(result.windows.first?.amount, "24.5")
        XCTAssertEqual(result.windows.first?.currency, "USD")
        XCTAssertNil(result.windows.first?.remainingBps)
        let second = try NativeProviderNormalizer.normalize(usage, providerID: "fal", alias: "Second key", source: .officialAPI)
        XCTAssertEqual(result.accountID, second.accountID)
    }
    func testFalMissingNegativeAndInvalidCurrencyRejected() {
        for body in [#"{"username":"team"}"#, #"{"username":"team","credits":{"current_balance":-1,"currency":"USD"}}"#,
                     #"{"username":"team","credits":{"current_balance":1,"currency":"bad"}}"#] {
            XCTAssertThrowsError(try FalUsageReader.parse(Data(body.utf8), now: now))
        }
    }
    func vercelRow(_ cost: String = "2.5", currency: String = "USD", category: String = "Usage") -> String {
        #"{"BilledCost":"\#(cost)","BillingCurrency":"\#(currency)","ChargeCategory":"\#(category)","ChargePeriodStart":"2026-09-01T00:00:00Z","ChargePeriodEnd":"2026-09-02T00:00:00Z"}"#
    }
    func testVercelSumsUsageOnlyPreservesZeroAndMonth() throws {
        let usage = try VercelUsageReader.parse(Data((vercelRow() + "\n" + vercelRow("20", category: "Purchase")).utf8), teamID: "team_demo", now: now)
        XCTAssertEqual(usage.cost?.used, 2.5)
        XCTAssertNil(usage.cost?.balance)
        let normalized = try NativeProviderNormalizer.normalize(usage, providerID: "vercel", alias: "Demo", source: .officialAPI)
        XCTAssertEqual(normalized.windows.first?.quotaKey, "cost-spend")
        XCTAssertNotNil(normalized.windows.first?.window.startsAt)
        XCTAssertNotNil(normalized.windows.first?.window.periodId)
        let zero = try VercelUsageReader.parse(Data(vercelRow("0").utf8), teamID: "team_demo", now: now)
        let zeroWindows = try NativeProviderNormalizer.normalize(zero, providerID: "vercel", alias: "Demo", source: .officialAPI).windows
        XCTAssertEqual(zeroWindows.first?.amount, "0")
        let snapshot = try Snapshot.make(windows: normalized.windows, deviceID: "demo", epoch: "demo", sequence: 1, capturedAt: now)
        XCTAssertEqual(try SnapshotCodec.decode(SnapshotCodec.encode(snapshot)).windows.first?.window.periodId, normalized.windows.first?.window.periodId)
    }
    func testVercelRejectsEmptyTruncatedMixedCurrencyAndURLInjection() {
        for body in ["", vercelRow() + "\n{", vercelRow() + "\n" + vercelRow(currency: "EUR"), vercelRow("2broken"), vercelRow("NaN"), #"{"error":"denied"}"#] {
            XCTAssertThrowsError(try VercelUsageReader.parse(Data(body.utf8), teamID: "team_demo", now: now))
        }
        XCTAssertThrowsError(try VercelUsageReader.requestURL(teamID: "team_demo&teamId=other", now: now))
    }
    func cfRow(_ cost: String, account: String = String(repeating: "a", count: 32), period: String = "2026-09-03T00:00:00Z") -> String {
        #"{"BillingAccountId":"\#(account)","BillingCurrency":"USD","BillingPeriodStart":"\#(period)","ContractedCost":\#(cost),"CumulatedContractedCost":999}"#
    }
    func testCloudflareUsesPeriodCostNotCumulativeAndPinsAccount() throws {
        let account = String(repeating: "a", count: 32)
        let data = Data((#"{"success":true,"result":["# + cfRow("2") + "," + cfRow("3") + "]}").utf8)
        let usage = try CloudflareUsageReader.parse(data, accountID: account, now: now)
        XCTAssertEqual(usage.cost?.used, 5)
        XCTAssertNotNil(usage.cost?.startsAt)
        XCTAssertNil(usage.cost?.resetsAt) // No fabricated billing end.
        XCTAssertThrowsError(try CloudflareUsageReader.parse(data, accountID: String(repeating: "b", count: 32), now: now))
        let mixed = Data((#"{"success":true,"result":["# + cfRow("2") + "," + cfRow("3", period: "2026-09-05T00:00:00Z") + "]}").utf8)
        XCTAssertThrowsError(try CloudflareUsageReader.parse(mixed, accountID: account, now: now))
        XCTAssertThrowsError(try CloudflareUsageReader.parse(Data(#"{"success":true,"result":[]}"#.utf8), accountID: account, now: now))
    }
    func testReplitGrossCostRetainsServerPeriodAndNoBalance() throws {
        let data = Data(#"{"data":{"interval":{"startTime":"2026-09-10T00:00:00Z","endTime":"2026-10-10T00:00:00Z"},"currency":"USD","totalCostUsd":12.4}}"#.utf8)
        let usage = try ReplitUsageReader.parse(data, apiKey: "rpl_synthetic", now: now)
        XCTAssertEqual(usage.cost?.used, 12.4)
        XCTAssertNil(usage.cost?.balance)
        XCTAssertNotNil(usage.cost?.periodID)
        XCTAssertThrowsError(try ReplitUsageReader.parse(data, apiKey: "rpl_synthetic", now: now.addingTimeInterval(60 * 86_400)))
        XCTAssertThrowsError(try ReplitUsageReader.parse(Data(#"{"data":{"totalCostUsd":0}}"#.utf8), apiKey: "rpl_synthetic", now: now))
    }
}
