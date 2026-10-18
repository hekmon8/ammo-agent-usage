import XCTest
import QuotaCore
import QuotaDesign

/// Provider-level grouping for the compact menu surface: merge by provider,
/// preserve snapshot order everywhere, and keep hidden providers off the list.
final class ProviderGroupTests: XCTestCase {
    var now: Date { QuotaRules.date("2026-09-05T01:41:00Z")! }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(name).json")) }

    private func windowDict(id: String, provider: String, account: String, alias: String,
                            quotaKey: String = "primary",
                            unit: String = "percent", amount: String? = nil, bps: Int? = 5_000) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: data("01-fresh")) as! [String: Any]
        var windows = object["windows"] as! [[String: Any]]
        windows[0]["id"] = id
        windows[0]["providerId"] = provider
        windows[0]["accountId"] = account
        windows[0]["accountAlias"] = alias
        windows[0]["quotaKey"] = quotaKey
        windows[0]["unit"] = unit
        windows[0]["amount"] = amount.map { $0 as NSString } ?? NSNull()
        windows[0]["currency"] = unit == "money" ? "USD" as NSString : NSNull()
        windows[0]["remainingBps"] = bps.map { $0 as NSNumber } ?? NSNull()
        return windows[0]
    }

    private func presentations(_ dicts: [[String: Any]]) throws -> [QuotaPresentation] {
        var object = try JSONSerialization.jsonObject(with: data("01-fresh")) as! [String: Any]
        object["windows"] = dicts
        let snapshot = try SnapshotCodec.decode(try JSONSerialization.data(withJSONObject: object))
        return snapshot.windows.map { QuotaPresentation(window: $0, now: now) }
    }

    func testDashboardCardsGroupByProviderAndAccountNotAliasOrCategory() throws {
        let values = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "personal"),
            windowDict(id: "w2", provider: "zai", account: "a1", alias: "personal"),
            windowDict(id: "w3", provider: "codex", account: "a2", alias: "personal"),
            windowDict(id: "w4", provider: "codex", account: "a1", alias: "personal", quotaKey: "secondary"),
            windowDict(id: "w5", provider: "codex", account: "a1", alias: "personal",
                       quotaKey: "credit-balance", unit: "money", amount: "12.50", bps: nil),
        ])
        let groups = QuotaAccountGroup.grouped(values)
        XCTAssertEqual(groups.map(\.providerID), ["codex", "zai", "codex"])
        XCTAssertEqual(groups.map { $0.values.map(\.window.id) }, [["w1", "w4", "w5"], ["w2"], ["w3"]])
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)

        let balances = QuotaAccountGroup.grouped(values.filter { QuotaCategory.balance.includes($0.window) })
        XCTAssertEqual(balances.map(\.id), [groups[0].id])
        XCTAssertEqual(balances[0].values.map(\.window.id), ["w5"])
        XCTAssertTrue(QuotaAccountGroup.grouped([]).isEmpty)
    }

    func testGroupsMergeAcrossAccountsInSnapshotOrder() throws {
        let values = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "个人", quotaKey: "primary"),
            windowDict(id: "w2", provider: "zai", account: "b1", alias: "edu"),
            windowDict(id: "w3", provider: "codex", account: "a2", alias: "work"),
            windowDict(id: "w4", provider: "codex", account: "a1", alias: "个人", quotaKey: "secondary"),
        ])
        let groups = QuotaProviderGroup.groups(values)
        XCTAssertEqual(groups.map(\.providerID), ["codex", "zai"])
        XCTAssertEqual(groups[0].values.map(\.window.id), ["w1", "w3", "w4"])
        XCTAssertEqual(groups[1].values.map(\.window.id), ["w2"])
    }

    func testHiddenProvidersLeaveEntirely() throws {
        let values = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "个人"),
            windowDict(id: "w2", provider: "zai", account: "b1", alias: "edu"),
        ])
        let groups = QuotaProviderGroup.groups(values, hiddenProviderIDs: ["codex"])
        XCTAssertEqual(groups.map(\.providerID), ["zai"])
        XCTAssertTrue(QuotaProviderGroup.groups(values, hiddenProviderIDs: ["codex", "zai"]).isEmpty)
        XCTAssertEqual(QuotaProviderGroup.groups([], hiddenProviderIDs: []).count, 0)
    }

    func testAccountSectionsOnlyWhenMultipleAccounts() throws {
        let single = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "个人", quotaKey: "primary"),
            windowDict(id: "w2", provider: "codex", account: "a1", alias: "个人", quotaKey: "secondary"),
        ])
        XCTAssertEqual(QuotaProviderGroup.groups(single)[0].accountSections.count, 0)

        let multi = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "个人", quotaKey: "primary"),
            windowDict(id: "w2", provider: "codex", account: "a2", alias: "work"),
            windowDict(id: "w3", provider: "codex", account: "a1", alias: "个人", quotaKey: "secondary"),
        ])
        let sections = QuotaProviderGroup.groups(multi)[0].accountSections
        XCTAssertEqual(sections.map(\.alias), ["个人", "work"])
        XCTAssertEqual(sections[0].values.map(\.window.id), ["w1", "w3"])
    }

    func testPercentValuesExcludeRatioLessWindows() throws {
        let values = try presentations([
            windowDict(id: "w1", provider: "codex", account: "a1", alias: "个人", quotaKey: "primary", unit: "percent", bps: 5_200),
            windowDict(id: "w2", provider: "codex", account: "a1", alias: "个人", quotaKey: "credit-balance", unit: "credits", amount: "0", bps: nil),
            windowDict(id: "w3", provider: "codex", account: "a1", alias: "个人", quotaKey: "rate-limit-reset-credits", unit: "requests", amount: "1", bps: nil),
        ])
        let group = QuotaProviderGroup.groups(values)[0]
        XCTAssertEqual(group.percentValues.map(\.window.id), ["w1"])
        XCTAssertEqual(group.values.count, 3)
    }
}
