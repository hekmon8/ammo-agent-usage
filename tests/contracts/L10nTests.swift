import XCTest
@testable import QuotaCore

final class L10nTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.simplifiedChinese)
    }

    override func tearDown() {
        L10n.resetLanguage()
        super.tearDown()
    }

    func testTablesResolveInBothLanguages() {
        L10n.setLanguage(.simplifiedChinese)
        XCTAssertEqual(L("language.option.system"), "跟随系统")
        L10n.setLanguage(.english)
        XCTAssertEqual(L("language.option.system"), "Follow System")
    }

    func testUsageFeatureTableResolvesWithoutChangingLegacyLookups() {
        XCTAssertEqual(L10n.table(for: "tokenUsage.title"), "TokenUsage")
        XCTAssertNil(L10n.table(for: "language.option.system"))
        L10n.setLanguage(.english)
        XCTAssertEqual(L("tokenUsage.title"), "Usage")
        XCTAssertEqual(L("language.option.system"), "Follow System")
        XCTAssertEqual(L10n.text("tokenUsage.missing.test"), "tokenUsage.missing.test")
        L10n.setLanguage(.simplifiedChinese)
        XCTAssertEqual(L("tokenUsage.title"), "用量")
        XCTAssertEqual(L("language.option.system"), "跟随系统")
    }

    func testMissingKeyFallsBackToKeyItself() {
        XCTAssertEqual(L("totally.missing.key"), "totally.missing.key")
    }

    func testRevisionBumpsAndNotificationFires() {
        let expectation = expectation(forNotification: L10n.languageDidChange, object: nil)
        let before = L10n.revision
        L10n.setLanguage(.english)
        XCTAssertEqual(L10n.revision, before + 1)
        wait(for: [expectation], timeout: 1)
    }

    func testOverrideSharesWithInstalledDefaultsSuite() {
        let identifier = "test.l10n.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: identifier) }
        let suite = UserDefaults(suiteName: identifier)!
        XCTAssertFalse(suite.bool(forKey: "unused"))
        L10n.install(additionalDefaults: suite)
        L10n.setLanguage(.english)
        XCTAssertEqual(suite.string(forKey: "quota.island.language"), "en")
        XCTAssertEqual(L10n.effectiveLanguageCode, "en")
    }

    /// Status lines outlive the event that produced them, so `LocalizedStatus`
    /// must resolve against whichever language is active at render time.
    func testLocalizedStatusRerendersAfterLanguageChange() {
        L10n.setLanguage(.english)
        let status = LocalizedStatus("island.sidebar.tagline")
        XCTAssertEqual(status.text, "Quotas at a glance")
        L10n.setLanguage(.simplifiedChinese)
        XCTAssertEqual(status.text, "额度，一眼可见")
    }

    func testLocalizedStatusFormatsArgumentsAndEmptyState() {
        L10n.setLanguage(.english)
        XCTAssertEqual(LocalizedStatus("island.overview.windowCount", 3).text, "3 windows")
        XCTAssertTrue(LocalizedStatus.empty.isEmpty)
        XCTAssertEqual(LocalizedStatus.empty.text, "")
        XCTAssertFalse(LocalizedStatus("island.sidebar.tagline").isEmpty)
    }

    func testSystemSettingKeepsEffectiveLookupFollowingPreferredLocalizations() {
        L10n.resetLanguage()
        XCTAssertTrue(["zh-Hans", "en"].contains(L10n.effectiveLanguageCode))
        XCTAssertEqual(L10n.currentSetting, .system)
    }
}
