import XCTest
import Foundation
import QuotaCore
import QuotaWidgets

final class WidgetTests: XCTestCase {
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

    func testExplicitWidgetChoicesOverrideDefaultsAndDeduplicate() {
        XCTAssertEqual(WidgetSelectionPolicy.resolve(configured: [], defaults: ["first", "second"]), ["first", "second"])
        XCTAssertEqual(WidgetSelectionPolicy.resolve(configured: ["third"], defaults: ["first", "second"]), ["third"])
        XCTAssertEqual(WidgetSelectionPolicy.resolve(configured: ["first", "first", "second"], defaults: []), ["first", "second"])
        XCTAssertEqual(WidgetFamilyKind.systemSmall.maximumWindowCount, 2)
        XCTAssertEqual(WidgetFamilyKind.systemMedium.maximumWindowCount, 2)
        XCTAssertEqual(WidgetFamilyKind.accessoryCircular.maximumWindowCount, 1)
    }

    func testThreeSelectedQuotasStayWithinOneTwoQuotaProjection() throws {
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        let windows = ["first", "second", "third"].map { id in
            QuotaWindow.reported(id: id, providerID: "codex", accountID: "account", alias: "Work", key: id,
                remainingBps: 6800, observedAt: now, staleAt: now.addingTimeInterval(600),
                duration: 18_000, resetsAt: nil, source: .userDefined)
        }
        let snapshot = try Snapshot.make(windows: windows, deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)
        let selected = ["second", "second", "first", "third"]
        XCTAssertEqual(WidgetSelectionPolicy.resolve(configured: [], defaults: selected), ["second", "first"])
        let projection = WidgetProjection(snapshot: snapshot, entryDate: now, fixedWindowIDs: selected)
        XCTAssertEqual(projection.values.map { $0.window.id }, ["second", "first"])
        XCTAssertEqual(projection.missingWindowSelectionCount, 0)
        XCTAssertEqual(snapshot.windows.count, 3)
    }

    func testTimelineIncludesBothStaleAndResetWithoutPredictingQuota() throws {
        let now = Date(timeIntervalSince1970: 1788572460)
        let window = QuotaWindow.reported(id: "test", providerID: "test", accountID: "test", alias: "Test", key: "test", remainingBps: 6800,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: 18000, resetsAt: now.addingTimeInterval(1200), source: .userDefined)
        let snapshot = try Snapshot.make(windows: [window], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)
        let projection = WidgetProjection(snapshot: snapshot, entryDate: now)
        XCTAssertEqual(WidgetTimelinePlanner.entryDates(for: projection), [600,1200,1800].map { now.addingTimeInterval(Double($0)) })
        let later = WidgetProjection(snapshot: snapshot, entryDate: now.addingTimeInterval(1200))
        XCTAssertEqual(later.values[0].state, .resetPending)
        XCTAssertEqual(later.values[0].visibleBps, 6800)
        XCTAssertEqual(later.values[0].window.observedAt, window.observedAt)
        XCTAssertEqual(WidgetProjection(snapshot: snapshot, entryDate: now, isLocked: true).values[0].visibleBps, nil)
    }

    func testMissingFixedWindowDoesNotFallBackOrMutateSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        let first = QuotaWindow.reported(id: "first", providerID: "test", accountID: "account", alias: "Test", key: "first", remainingBps: 6800,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: 18_000, resetsAt: nil, source: .userDefined)
        let second = QuotaWindow.reported(id: "second", providerID: "test", accountID: "account", alias: "Test", key: "second", remainingBps: 4200,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: 18_000, resetsAt: nil, source: .userDefined)
        let snapshot = try Snapshot.make(windows: [first, second], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)

        let projection = WidgetProjection(snapshot: snapshot, entryDate: now, fixedWindowID: "missing")

        XCTAssertTrue(projection.isFixedWindowUnknown)
        XCTAssertEqual(projection.values.count, 0)
        XCTAssertEqual(snapshot.windows.map { $0.id }, ["first", "second"])
    }

    func testConfiguredWindowsStayInOrderAndMediumProjectionStaysBounded() throws {
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        let windows = ["first", "fixed", "third"].map { id in
            QuotaWindow.reported(id: id, providerID: "test", accountID: "account", alias: "Test", key: id, remainingBps: 6800,
                observedAt: now, staleAt: now.addingTimeInterval(600), duration: 18_000, resetsAt: nil, source: .userDefined)
        }
        let snapshot = try Snapshot.make(windows: windows, deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)

        let projection = WidgetProjection(snapshot: snapshot, entryDate: now, fixedWindowIDs: ["fixed", "third"])

        XCTAssertEqual(projection.values.map { $0.window.id }, ["fixed", "third"])
        XCTAssertLessThanOrEqual(projection.values.count, 2)
        XCTAssertEqual(snapshot.windows.map { $0.id }, ["first", "fixed", "third"])
    }

    func testMissingSecondarySelectionIsReportedWithoutSubstitution() throws {
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        let window = QuotaWindow.reported(id: "fixed", providerID: "codex", accountID: "account", alias: "Work", key: "five-hour", remainingBps: 6800,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: 18_000, resetsAt: nil, source: .userDefined)
        let snapshot = try Snapshot.make(windows: [window], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)

        let projection = WidgetProjection(snapshot: snapshot, entryDate: now, fixedWindowIDs: ["fixed", "removed"])

        XCTAssertEqual(projection.values.map { $0.window.id }, ["fixed"])
        XCTAssertEqual(projection.missingWindowSelectionCount, 1)
        XCTAssertTrue(projection.stateText.contains("固定窗口已丢失"))
    }

    func testEntityResolverRetainsMissingConfiguredWindowAsUnavailable() {
        let available = WidgetWindowDescriptor(
            id: "available",
            providerID: "codex",
            providerName: "Codex",
            accountAlias: "Work",
            windowName: "five-hour"
        )

        let resolved = WidgetWindowEntityResolver.descriptors(
            for: ["available", "removed"],
            in: [available]
        )

        XCTAssertEqual(resolved.map(\.id), ["available", "removed"])
        XCTAssertEqual(resolved[1].providerName, "窗口已不可用")
        XCTAssertEqual(resolved[1].windowName, "请重新选择")
    }

    func testLegacyWidgetDescriptorDecodesWithoutGuessingPeriod() throws {
        let old = Data(#"{"id":"fixed","providerID":"codex","providerName":"Codex","accountAlias":"Account 1","windowName":"primary"}"#.utf8)
        let descriptor = try JSONDecoder().decode(WidgetWindowDescriptor.self, from: old)
        XCTAssertEqual(descriptor.id, "fixed")
        XCTAssertNil(descriptor.quotaKey)
        XCTAssertNil(descriptor.windowDurationSeconds)
        XCTAssertEqual(descriptor.localizedWindowName, "主要额度")
        XCTAssertEqual(descriptor.localizedAccountAlias, "Account 1")
        L10n.setLanguage(.english)
        XCTAssertEqual(descriptor.localizedWindowName, "Primary quota")
        XCTAssertFalse(descriptor.localizedWindowName.contains("5h"))
    }

    func testLegacyFriendlyWidgetDescriptorAndTombstoneStayReadable() {
        let descriptor = WidgetWindowDescriptor(id: "fixed", providerID: "codex", providerName: "Codex",
                                               accountAlias: "Account 2", windowName: "Research quota")
        XCTAssertEqual(descriptor.localizedWindowName, "Research quota")
        let missing = WidgetWindowEntityResolver.descriptors(for: ["fixed", "removed"], in: [descriptor])
        XCTAssertEqual(missing.map(\.id), ["fixed", "removed"])
        XCTAssertEqual(missing[1].localizedWindowName, "请重新选择")
    }

    func testLegacySelectorSlugsHaveReadableNamesWithoutRewritingIDs() {
        for (provider, key) in [("amp", "balance"), ("amp", "free-balance"), ("cloudflare", "cost-spend"),
                                ("codex", "credit-balance"), ("codex", "rate-limit-reset-credits")] {
            let descriptor = WidgetWindowDescriptor(id: key, providerID: provider, providerName: provider,
                                                   accountAlias: "账户 1", windowName: key)
            XCTAssertNotEqual(descriptor.localizedWindowName, key)
            XCTAssertFalse(descriptor.localizedWindowName.contains("quota.label."))
            XCTAssertEqual(descriptor.id, key)
        }
    }

    func testLegacySparkSelectorsRetainPrimarySecondaryDistinction() {
        let pairs = [("codex-spark", "codex-spark-weekly"), ("spark-primary", "spark-secondary"),
                     ("codex-spark-primary", "codex-spark-secondary"), ("codex_bengalfox-primary", "codex_bengalfox-secondary")]
        for (primaryKey, secondaryKey) in pairs {
            let primary = WidgetWindowDescriptor(id: primaryKey, providerID: "codex", providerName: "Codex",
                                                 accountAlias: "账户 1", windowName: primaryKey)
            let secondary = WidgetWindowDescriptor(id: secondaryKey, providerID: "codex", providerName: "Codex",
                                                   accountAlias: "账户 1", windowName: secondaryKey)
            XCTAssertNotEqual(primary.localizedWindowName, secondary.localizedWindowName)
            XCTAssertTrue(primary.localizedWindowName.contains(L("widget.intent.primaryWindow")))
            XCTAssertTrue(secondary.localizedWindowName.contains(L("widget.intent.secondaryWindow")))
            XCTAssertFalse(primary.localizedWindowName.contains("5"))
            XCTAssertEqual(WidgetWindowEntityResolver.descriptors(for: [primary.id, secondary.id], in: [primary, secondary]).map(\.id), [primary.id, secondary.id])
        }
    }

    func testWidgetDescriptorLocalizesAfterDecodeWithoutChangingChoiceOrLeakingAccount() throws {
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        let window = QuotaWindow.reported(id: "fixed", providerID: "codex", accountID: "private-account-id",
            alias: "Private account name", key: "primary", remainingBps: 6800,
            observedAt: now, staleAt: now.addingTimeInterval(600), duration: 7 * 86_400,
            resetsAt: nil, source: .userDefined)
        let descriptor = WidgetWindowDescriptor(window: window, accountOrdinal: 2)
        XCTAssertEqual(descriptor.windowName, window.shortDisplayName)
        XCTAssertEqual(descriptor.localizedWindowName, "周限额")
        XCTAssertEqual(descriptor.localizedAccountAlias, "账户 2")
        let encoded = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("private-account-id"))
        XCTAssertFalse(json.contains("Private account name"))
        XCTAssertFalse(json.contains("6800"))
        XCTAssertFalse(json.contains("observedAt"))
        let decoded = try JSONDecoder().decode(WidgetWindowDescriptor.self, from: encoded)
        L10n.setLanguage(.english)
        XCTAssertEqual(decoded.localizedWindowName, "Weekly limit")
        XCTAssertEqual(decoded.localizedAccountAlias, "Account 2")
        XCTAssertEqual(decoded.id, window.id)
        XCTAssertEqual(WidgetWindowEntityResolver.descriptors(for: ["fixed"], in: [decoded]).map(\.id), ["fixed"])
        XCTAssertEqual(WidgetSelectionPolicy.resolve(configured: ["fixed"], defaults: []), ["fixed"])
    }

    func testWidgetDescriptorUsesActualDurationAndKeepsUnknownPeriodUnknown() {
        let weekly = WidgetWindowDescriptor(id: "week", providerID: "codex", providerName: "Codex",
            accountAlias: "Account 1", windowName: "primary", quotaKey: "primary", unit: .percent,
            windowDurationSeconds: 7 * 86_400)
        let spark = WidgetWindowDescriptor(id: "spark", providerID: "codex", providerName: "Codex",
            accountAlias: "Account 1", windowName: "spark-primary", quotaKey: "spark-primary", unit: .percent,
            windowDurationSeconds: 6 * 3_600)
        let unknown = WidgetWindowDescriptor(id: "unknown", providerID: "codex", providerName: "Codex",
            accountAlias: "Account 1", windowName: "primary", quotaKey: "primary", unit: .percent)
        XCTAssertEqual(weekly.localizedWindowName, "周限额")
        XCTAssertEqual(spark.localizedWindowName, "Spark · 6小时限额")
        XCTAssertEqual(unknown.localizedWindowName, L("widget.intent.primaryWindow"))
        XCTAssertEqual(QuotaWindow.shortDisplayName(providerID: "codex", quotaKey: "credit-balance", unit: .credits,
                                                   windowDurationSeconds: nil), L("quota.label.creditBalance"))
    }

    func testNewCatalogWithoutDurationsKeepsPairedChoicesDistinctAfterDecode() throws {
        let pairs = [("primary", "secondary"), ("codex-primary", "codex-secondary"), ("default-primary", "default-secondary"),
                     ("codex-spark", "codex-spark-weekly"), ("spark-primary", "spark-secondary"),
                     ("codex-spark-primary", "codex-spark-secondary"), ("codex_bengalfox-primary", "codex_bengalfox-secondary")]
        for (first, second) in pairs {
            let catalog = [first, second].map { key in
                WidgetWindowDescriptor(id: key, providerID: "codex", providerName: "Codex", accountAlias: "账户 1",
                                       windowName: "Quota", quotaKey: key, unit: .percent, accountOrdinal: 1)
            }
            let decoded = try JSONDecoder().decode([WidgetWindowDescriptor].self, from: JSONEncoder().encode(catalog))
            for language in [QuotaLanguage.simplifiedChinese, .english] {
                L10n.setLanguage(language)
                XCTAssertNotEqual(decoded[0].localizedWindowName, decoded[1].localizedWindowName)
                XCTAssertTrue(decoded[0].localizedWindowName.contains(L("widget.intent.primaryWindow")))
                XCTAssertTrue(decoded[1].localizedWindowName.contains(L("widget.intent.secondaryWindow")))
                XCTAssertEqual(decoded.map(\.id), [first, second])
            }
        }
    }

    func testActivityDisplaySemanticsMakesStaleLowHistoricalOnEveryHost() {
        let presentation = ActivityDisplaySemantics(
            remainingBps: 800,
            displayState: "low",
            observedAt: 900,
            staleAt: 1_000,
            resetsAt: nil,
            endsAt: 2_000,
            now: 1_100
        )

        XCTAssertEqual(presentation.number, "8%")
        XCTAssertEqual(presentation.status, "上次记录 · 待更新")
        XCTAssertEqual(presentation.symbol, "clock")
        XCTAssertEqual(presentation.visualState, .historical)
        XCTAssertNil(presentation.remainingBps)
    }

    func testActivityDisplaySemanticsKeepsLastReadingForExpiredAuthorization() {
        let unauthorized = ActivityDisplaySemantics(
            remainingBps: 800,
            displayState: "authRequired",
            observedAt: 900,
            staleAt: 1_000,
            resetsAt: nil,
            endsAt: 2_000,
            now: 1_100
        )

        XCTAssertEqual(unauthorized.number, "8%")
        XCTAssertEqual(unauthorized.status, "需要授权 · 已暂停更新")
        XCTAssertEqual(unauthorized.symbol, "key.fill")
        XCTAssertEqual(unauthorized.visualState, .historical)
        XCTAssertNil(unauthorized.remainingBps)
    }

    func testActivityDisplaySemanticsMakesResetAndEndedHistoricalBeforeWarnings() {
        let resetPending = ActivityDisplaySemantics(
            remainingBps: 0,
            displayState: "low",
            observedAt: 900,
            staleAt: 1_900,
            resetsAt: 1_000,
            endsAt: 2_000,
            now: 1_100
        )
        XCTAssertEqual(resetPending.status, "上次记录 · 重置待确认")
        XCTAssertEqual(resetPending.visualState, .historical)

        let ended = ActivityDisplaySemantics(
            remainingBps: 0,
            displayState: "low",
            observedAt: 900,
            staleAt: 1_900,
            resetsAt: 1_000,
            endsAt: 2_000,
            now: 2_000
        )
        XCTAssertEqual(ended.status, "系统已结束显示 · 上次记录")
        XCTAssertEqual(ended.number, "0%")
        XCTAssertEqual(ended.visualState, .ended)
    }

    func testExplicitHistoricalDisplayStatesOutrankFutureTimestamps() {
        let stale = ActivityDisplaySemantics(
            remainingBps: 800,
            displayState: "stale",
            observedAt: 1_400,
            staleAt: 1_500,
            resetsAt: nil,
            endsAt: 2_000,
            now: 1_100
        )
        XCTAssertEqual(stale.status, "上次记录 · 待更新")
        XCTAssertEqual(stale.visualState, .historical)

        let resetPending = ActivityDisplaySemantics(
            remainingBps: 800,
            displayState: "resetPending",
            observedAt: 1_400,
            staleAt: 1_500,
            resetsAt: 2_000,
            endsAt: 3_000,
            now: 1_100
        )
        XCTAssertEqual(resetPending.status, "上次记录 · 重置待确认")
        XCTAssertEqual(resetPending.visualState, .historical)
    }

    func testSystemStalenessCannotRenderAFreshPayloadAsCurrent() {
        let presentation = ActivityDisplaySemantics(remainingBps: 800, displayState: "low", observedAt: 1_000, staleAt: 5_000, resetsAt: nil, endsAt: 9_000, now: 1_100, systemIsStale: true)
        XCTAssertEqual(presentation.number, "8%")
        XCTAssertEqual(presentation.status, "上次记录 · 待更新")
        XCTAssertEqual(presentation.visualState, .historical)
        XCTAssertNil(presentation.remainingBps)
    }

    func testMissingObservationCannotClaimAFreshQuota() {
        let presentation = ActivityDisplaySemantics(remainingBps: 7300, displayState: "fresh", observedAt: nil, staleAt: 5_000, resetsAt: nil, endsAt: 9_000, now: 1_100)
        XCTAssertEqual(presentation.number, "73%")
        XCTAssertEqual(presentation.visualState, .historical)
        XCTAssertNil(presentation.remainingBps)
    }

    func testEndedCardKeepsLastPercentageAndNeverClaimsCurrentProgress() {
        for state in ["low", "offline", "stale", "systemEnded"] {
            let presentation = ActivityDisplaySemantics(remainingBps: 7300, displayState: state, observedAt: 900, staleAt: 5_000, resetsAt: 6_000, endsAt: 2_000, now: 2_000)
            XCTAssertEqual(presentation.number, "73%")
            XCTAssertEqual(presentation.status, "系统已结束显示 · 上次记录")
            XCTAssertEqual(presentation.visualState, .ended)
            XCTAssertNil(presentation.remainingBps)
        }
    }

    func testExplicitStopAndOfflineKeepDistinctHistoricalStatuses() {
        let stopped = ActivityDisplaySemantics(remainingBps: 7300, displayState: "ended", observedAt: 900, staleAt: 5_000, resetsAt: nil, endsAt: 8_000, now: 1_100)
        XCTAssertEqual(stopped.status, "已停止显示 · 上次记录")
        XCTAssertEqual(stopped.number, "73%")
        XCTAssertEqual(stopped.visualState, .ended)
        let offline = ActivityDisplaySemantics(remainingBps: 7300, displayState: "offline", observedAt: 900, staleAt: 5_000, resetsAt: nil, endsAt: 8_000, now: 1_100, systemIsStale: true)
        XCTAssertEqual(offline.status, "暂未更新 · 上次记录")
        XCTAssertEqual(offline.number, "73%")
        XCTAssertEqual(offline.visualState, .historical)
        XCTAssertNil(offline.remainingBps)
    }

    func testUnlimitedActivityHasNoProgressValue() {
        let unlimited = ActivityDisplaySemantics(
            remainingBps: 8_000,
            displayState: "unlimited",
            observedAt: 1_000,
            staleAt: 2_000,
            resetsAt: nil,
            endsAt: 3_000,
            now: 1_100
        )

        XCTAssertEqual(unlimited.number, "未设上限")
        XCTAssertNil(unlimited.remainingBps)
        XCTAssertEqual(unlimited.visualState, .normal)
    }
}

#if os(iOS)
extension WidgetTests {
    func testLegacyActivityOptionsDecodeToCalibratedStyle() throws {
        let oldPayload = """
        {"sessionID":"session","windowID":"window","endsAt":2000,
         "displayOptions":{"showWindowName":false,"showProgress":true,"showObservationTime":false}}
        """

        let decoded = try JSONDecoder().decode(QuotaActivityAttributes.self, from: Data(oldPayload.utf8))

        XCTAssertEqual(decoded.displayOptions?.showWindowName, false)
        XCTAssertEqual(decoded.displayOptions?.showProgress, true)
        XCTAssertEqual(decoded.displayOptions?.showObservationTime, false)
        XCTAssertEqual(decoded.displayOptions?.displayStyle, .calibrated)
    }

    func testActivityPresentationTreatsStaleLowAsHistoricalBeforeWarning() {
        let content = QuotaActivityAttributes.ContentState(
            remainingBps: 800,
            displayState: "low",
            observedAt: 900,
            staleAt: 1_000,
            resetsAt: nil,
            label: "codex · five-hour",
            sequence: 4
        )

        let presentation = ActivityStatusPresentation(state: content, endsAt: 2_000, now: 1_100)

        XCTAssertEqual(presentation.number, "8%")
        XCTAssertEqual(presentation.status, "上次记录 · 待更新")
        XCTAssertEqual(presentation.symbol, "clock")
        XCTAssertEqual(presentation.visualState, .historical)
        XCTAssertNil(presentation.remainingBps)
    }

    func testActivityPresentationUsesTimestampFreshnessBeforeLowAndEndedState() {
        let content = QuotaActivityAttributes.ContentState(
            remainingBps: 0,
            displayState: "low",
            observedAt: 900,
            staleAt: 1_900,
            resetsAt: 1_000,
            label: "codex · five-hour",
            sequence: 4
        )

        let resetPending = ActivityStatusPresentation(state: content, endsAt: 2_000, now: 1_100)
        XCTAssertEqual(resetPending.status, "上次记录 · 重置待确认")
        XCTAssertEqual(resetPending.visualState, .historical)

        let ended = ActivityStatusPresentation(state: content, endsAt: 2_000, now: 2_000)
        XCTAssertEqual(ended.status, "系统已结束显示 · 上次记录")
        XCTAssertEqual(ended.number, "0%")
        XCTAssertEqual(ended.visualState, .ended)
    }
}
#endif
