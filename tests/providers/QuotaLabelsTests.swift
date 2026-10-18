import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

final class QuotaLabelsTests: XCTestCase {
    // Localized model strings resolve through L10n; pin the language so the
    // zh-Hans literals below assert table contents deterministically.
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.simplifiedChinese)
    }

    override func tearDown() {
        L10n.resetLanguage()
        super.tearDown()
    }

    func testPoeCreditBalanceKeepsPointUnit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = QuotaWindow.providerValue(id: "poe-points-test", providerID: "poe", accountID: "account-test", alias: "Test",
            key: "credit-balance", unit: .credits, currency: nil, remainingBps: nil, amount: "123.45", limit: nil,
            quality: .reported, source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
            windowKind: .unknown, duration: nil, resetsAt: nil)
        let presentation = QuotaPresentation(window: window, now: now)
        XCTAssertEqual(window.shortDisplayName, "可用点数")
        XCTAssertEqual(presentation.number, "123.45 点")
        XCTAssertEqual(presentation.state, .fresh)
    }

    func testZeroSpendIsNotAnExhaustedBalance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func money(_ key: String) -> QuotaWindow {
            .providerValue(id: "money-test", providerID: "openai", accountID: "account-test", alias: "Test",
                key: key, unit: .money, currency: "USD", remainingBps: nil, amount: "0", limit: nil,
                quality: .reported, source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
                windowKind: .unknown, duration: nil, resetsAt: nil)
        }
        let spend = QuotaPresentation(window: money("cost-spend"), now: now)
        let balance = QuotaPresentation(window: money("balance"), now: now)
        XCTAssertEqual(spend.state, .fresh)
        XCTAssertEqual(spend.window.shortDisplayName, "本期消费")
        XCTAssertEqual(spend.valueHeading, "已消费")
        XCTAssertEqual(balance.state, .exhausted)
        XCTAssertEqual(balance.valueHeading, "剩余")
    }

    func testCodexUsesActualPeriodAndNamesSparkWithoutInternalIdentifiers() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1800430200}},"codex_bengalfox":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1800018000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1800604800}},"future_product":{"primary":{"usedPercent":30,"windowDurationMins":300}}}}"#.utf8)
        let windows = try CodexNormalizer.normalize(data, accountID: "account-test", alias: "Test", now: now)
        let byKey = Dictionary(uniqueKeysWithValues: windows.map { ($0.quotaKey, $0) })
        XCTAssertEqual(byKey["codex-primary"]?.shortDisplayName, "周限额")
        XCTAssertEqual(byKey["codex_bengalfox-primary"]?.shortDisplayName, "Spark · 5小时限额")
        XCTAssertEqual(byKey["codex_bengalfox-secondary"]?.shortDisplayName, "Spark · 周限额")
        XCTAssertEqual(byKey["future_product-primary"]?.shortDisplayName, "额外额度 · 5小时限额")
        XCTAssertEqual(byKey["codex-primary"]?.resetDescription(now: now), "4天23小时后重置")
        XCTAssertEqual(byKey["codex_bengalfox-primary"]?.resetDescription(now: now), "5小时后重置")
        XCTAssertEqual(byKey["codex_bengalfox-secondary"]?.resetDescription(now: now.addingTimeInterval(604_801)), "等待额度更新")
        XCTAssertNil(byKey["future_product-primary"]?.resetDescription(now: now))
    }

    func testMissingPeriodDoesNotInventFiveHourOrWeeklyWindow() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":10},"secondary":{"usedPercent":20}}}"#.utf8)
        let windows = try CodexNormalizer.normalize(data, accountID: "account-test", alias: "Test", now: Date())
        XCTAssertEqual(windows.map(\.shortDisplayName), ["额度", "额度"])
    }

    func testFactoryWindowsGetDistinctNames() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func factoryWindow(_ key: String, durationMinutes: Int?) -> QuotaWindow {
            .providerValue(id: "factory-label-test", providerID: "factory", accountID: "account-test", alias: "Droid",
                key: key, unit: .percent, currency: nil, remainingBps: 9_000, amount: nil, limit: nil,
                quality: .reported, source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
                windowKind: durationMinutes == nil ? .unknown : .rolling,
                duration: durationMinutes.map { $0 * 60 }, resetsAt: nil)
        }
        XCTAssertEqual(factoryWindow("primary", durationMinutes: 300).shortDisplayName, "标准 · 5小时限额")
        XCTAssertEqual(factoryWindow("secondary", durationMinutes: 10_080).shortDisplayName, "标准 · 周限额")
        XCTAssertEqual(factoryWindow("tertiary", durationMinutes: nil).shortDisplayName, "标准 · 月度限额")
        XCTAssertEqual(factoryWindow("core-5h", durationMinutes: 300).shortDisplayName, "Core · 5小时限额")
        XCTAssertEqual(factoryWindow("core-7d", durationMinutes: 10_080).shortDisplayName, "Core · 周限额")
        XCTAssertEqual(factoryWindow("core-monthly", durationMinutes: nil).shortDisplayName, "Core · 月度限额")
        XCTAssertEqual(factoryWindow("compute", durationMinutes: nil).shortDisplayName, "托管计算机")
    }

    func testIdleUnusedWindowsAreRecognizedForResetCopy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Factory's live shape: zero-use standard windows (including the
        // duration-less monthly) carry no window end, while a used core
        // window does. Mirrors NativeAPIReaderTests fixtures.
        let auth = Data(#"{"userProfile":{"id":"user-1","email":"me@example.com"}}"#.utf8)
        let limits = Data("""
        {"usesTokenRateLimitsBilling":true,
          "limits":{"standard":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                                 "weekly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                                 "monthly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null}},
                    "core":{"fiveHour":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                            "weekly":{"usedPercent":0,"windowEnd":null,"secondsRemaining":null},
                            "monthly":{"usedPercent":20,"windowEnd":"2026-09-24T00:12:53.943Z","secondsRemaining":782129}}}}
        """.utf8)
        let usage = try FactoryUsageReader.parse(authData: auth, limitsData: limits, usageData: nil,
                                                credential: NativeProviderCredential(kind: .apiKey, value: "sk-or-v1-0123456789abcdef0123456789abcdef"))
        let normalized = try NativeProviderNormalizer.normalize(
            usage, providerID: "factory", alias: "Droid", source: .officialAPI)
        let byKey = Dictionary(uniqueKeysWithValues: normalized.windows.map { ($0.quotaKey, $0) })
        // Untouched windows have no reset to count down to, whatever their duration.
        XCTAssertTrue(try XCTUnwrap(byKey["primary"]).isIdleWindow)
        XCTAssertTrue(try XCTUnwrap(byKey["secondary"]).isIdleWindow)
        XCTAssertTrue(try XCTUnwrap(byKey["tertiary"]).isIdleWindow)
        XCTAssertNil(try XCTUnwrap(byKey["primary"]).resetDescription(now: now))
        // The used core-monthly window keeps its real reset time and is not idle.
        XCTAssertFalse(try XCTUnwrap(byKey["core-monthly"]).isIdleWindow)
        XCTAssertNotNil(try XCTUnwrap(byKey["core-monthly"]).resetDescription(now: now))
        // Money balances and used windows never count as idle.
        let balance = QuotaWindow.providerValue(id: "idle-money-test", providerID: "factory", accountID: "account-test",
            alias: "Droid", key: "balance", unit: .money, currency: "USD", remainingBps: nil, amount: "5",
            limit: nil, quality: .reported, source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
            windowKind: .unknown, duration: nil, resetsAt: nil)
        XCTAssertFalse(balance.isIdleWindow)
    }

    func testResetCardWindowsUseCardCopyForBothPeriods() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func card(_ key: String, resetsAt: Date?, observedAt: Date? = nil, amount: String = "2") -> QuotaWindow {
            let observed = observedAt ?? now
            return .providerValue(id: "zai-reset-label-test", providerID: "zai", accountID: "account-test", alias: "lite plan",
                key: key, unit: .requests, currency: nil, remainingBps: nil, amount: amount, limit: nil,
                quality: .reported, source: .officialAPI, observedAt: observed, staleAt: observed.addingTimeInterval(600),
                windowKind: .unknown, duration: nil, resetsAt: resetsAt)
        }
        XCTAssertEqual(card("rate-limit-reset-credits", resetsAt: nil).shortDisplayName, "可用重置次数")
        XCTAssertEqual(card("rate-limit-reset-credits-week", resetsAt: nil).shortDisplayName, "可用周重置次数")
        XCTAssertEqual(QuotaPresentation(window: card("rate-limit-reset-credits", resetsAt: nil), now: now).number, "2 次")
        // English pluralizes the reset count; the generic request unit would
        // render the singular as "1 requests".
        L10n.setLanguage(.english)
        XCTAssertEqual(QuotaPresentation(window: card("rate-limit-reset-credits", resetsAt: nil), now: now).number, "2 resets")
        XCTAssertEqual(QuotaPresentation(window: card("rate-limit-reset-credits", resetsAt: nil, amount: "1"), now: now).number, "1 reset")
        L10n.setLanguage(.simplifiedChinese)
        for key in ["rate-limit-reset-credits", "rate-limit-reset-credits-week"] {
            XCTAssertEqual(card(key, resetsAt: nil).resetDescription(now: now), "未提供到期时间")
            // Observed before the deadline, refreshed past it: the card inventory
            // is outdated rather than a pending provider refresh.
            let expired = QuotaPresentation(
                window: card(key, resetsAt: now.addingTimeInterval(-60), observedAt: now.addingTimeInterval(-120)),
                now: now)
            XCTAssertEqual(expired.state, .stale)
        }
    }
}
