import Foundation
import XCTest
import QuotaDesign
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
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

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var now: Date { QuotaRules.date("2026-09-05T01:41:00Z")! }
    func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(name).json")) }
    func snapshot(_ name: String) throws -> Snapshot { try SnapshotCodec.decode(data(name)) }
    func projection(_ name: String, at time: Date? = nil) throws -> QuotaPresentation {
        QuotaPresentation(window: try snapshot(name).windows[0], now: time ?? now)
    }
    func mutated(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data("01-fresh")) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    func mutateWindow(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        try mutated { object in
            var windows = object["windows"] as! [[String: Any]]
            edit(&windows[0]); object["windows"] = windows
        }
    }
    func testAllGoldenRoundTripsAndSchemaCopy() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("contracts/fixtures"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(urls.count, 12)
        for url in urls {
            let original = try Data(contentsOf: url)
            let encoded = try SnapshotCodec.encode(SnapshotCodec.decode(original))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary, try JSONSerialization.jsonObject(with: encoded) as? NSDictionary, url.lastPathComponent)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("contracts/snapshot.schema.json")), try Data(contentsOf: root.appendingPathComponent("packages/QuotaCore/Sources/QuotaCore/Resources/snapshot.schema.json")))
    }
    func testDATA01Normalization() throws {
        XCTAssertEqual(try QuotaRules.remainingBps(usedPercent: "32"), 6800)
        XCTAssertEqual(try QuotaRules.remainingBps(usedPercent: "32.005"), 6799)
        XCTAssertEqual(try QuotaRules.remainingBps(usedPercent: "0"), 10000)
        XCTAssertEqual(try QuotaRules.remainingBps(usedPercent: "100"), 0)
        for invalid in ["-1", "101", "NaN", "Infinity", "true", "", "32junk"] {
            XCTAssertThrowsError(try QuotaRules.remainingBps(usedPercent: invalid))
        }
        XCTAssertEqual(try projection("01-fresh").number, "68%")
        XCTAssertEqual(try projection("01-fresh").activeTicks, 34)
        XCTAssertEqual(try projection("12-full").number, "100%")
    }
    func testDATA02NoInventedSecondary() throws {
        XCTAssertEqual(try snapshot("01-fresh").windows.map(\.quotaKey), ["primary"])
    }
    func testDATA03UnknownUnlimitedAndExhausted() throws {
        XCTAssertEqual(try projection("05-unavailable").number, "—")
        XCTAssertEqual(try projection("05-unavailable").state, .unavailable)
        XCTAssertNil(try projection("05-unavailable").visibleBps)
        XCTAssertEqual(try projection("06-unlimited").state, .unlimited)
        XCTAssertEqual(try projection("06-unlimited").number, "未设上限")
        XCTAssertEqual(try projection("11-exhausted").state, .exhausted)
        XCTAssertEqual(try projection("11-exhausted").number, "0%")
        XCTAssertEqual(try projection("02-low").state, .low)
        let unauthorized = try projection("07-auth-required")
        XCTAssertEqual(unauthorized.state, .authRequired)
        XCTAssertEqual(unauthorized.number, "68%")
        XCTAssertEqual(unauthorized.visibleBps, 6800)
        XCTAssertEqual(unauthorized.valueHeading, "上次记录剩余")
        XCTAssertTrue(unauthorized.status.contains("需要授权"))
        XCTAssertEqual(try projection("09-money").number, "42.60 USD")
        XCTAssertNil(try projection("09-money").visibleBps)
    }
    func testDATA04FreshnessAndResetNeverRefill() throws {
        XCTAssertEqual(try projection("03-stale").state, .stale)
        let reset = try projection("04-reset-pending")
        XCTAssertEqual(reset.state, .resetPending)
        XCTAssertEqual(reset.number, "68%")
        let window = try snapshot("01-fresh").windows[0]
        XCTAssertEqual(QuotaRules.state(window, now: QuotaRules.date(window.staleAt!)!), .stale)
        XCTAssertEqual(QuotaRules.state(window, now: QuotaRules.date(window.window.resetsAt!)!), .resetPending)
        let recaptured = try mutated { $0["capturedAt"] = "2026-09-06T01:41:00Z" }
        XCTAssertEqual(QuotaRules.state(try SnapshotCodec.decode(recaptured).windows[0], now: now.addingTimeInterval(900)), .stale)
        XCTAssertEqual(QuotaRules.trendSegments(try snapshot("10-gap").windows[0].history, interval: 600).map(\.count), [2, 2])
        let points = window.history
        XCTAssertEqual(QuotaRules.trendSegments(points).count, 1)
        XCTAssertEqual(QuotaRules.trendSegments([points[1], points[0]]).count, 2)
        let changed = HistoryPoint(observedAt: points[1].observedAt, remainingBps: 9000, segmentId: "next")
        XCTAssertEqual(QuotaRules.trendSegments([points[0], changed]).count, 2)
        let gap = HistoryPoint(observedAt: points[1].observedAt, remainingBps: nil, segmentId: "seg_01")
        XCTAssertEqual(QuotaRules.trendSegments([points[0], gap, points[2]]).count, 2)
    }
    func testDATA05SeparateWindows() throws {
        XCTAssertEqual(try snapshot("08-multiple-windows").windows.map(\.remainingBps), [6800, 4200, 2400])
    }
    func testLockedOfflineClockSkewAndFetchFailure() throws {
        let window = try snapshot("01-fresh").windows[0]
        let locked = QuotaPresentation(window: window, now: now, locked: true)
        XCTAssertEqual(locked.state, .locked); XCTAssertEqual(locked.number, "—"); XCTAssertNil(locked.visibleBps)
        XCTAssertEqual(QuotaPresentation(window: window, now: now, clockOffset: 121).state, .clockSkew)
        XCTAssertEqual(QuotaPresentation(window: window, now: now.addingTimeInterval(-121)).state, .clockSkew)
        XCTAssertTrue(QuotaPresentation(window: window, now: now, offline: true).isHistorical)
        XCTAssertTrue(QuotaPresentation(window: window, now: now, offline: true).status.contains("Mac 暂未更新"))
        let error = try SnapshotCodec.decode(mutateWindow { $0["fetchOutcome"] = "error" }).windows[0]
        XCTAssertEqual(QuotaPresentation(window: error, now: now).number, "68%")
        XCTAssertTrue(QuotaPresentation(window: error, now: now).isHistorical)
        XCTAssertEqual(try projection("06-unlimited", at: now.addingTimeInterval(900)).state, .stale)
    }
    func testStrictRejectsMalformedWireData() throws {
        let invalid: [Data] = try [
            mutated { $0["schemaVersion"] = "2.0.0" },
            mutated { $0["extra"] = "not allowed" },
            mutated { $0["sourceSequence"] = true },
            mutated { $0["sourceSequence"] = 9_007_199_254_740_992 as Int64 },
            mutated { $0["windows"] = Array(repeating: ($0["windows"] as! [Any])[0], count: 2) },
            mutateWindow { $0.removeValue(forKey: "amount") },
            mutateWindow { $0["remainingBps"] = -1 },
            mutateWindow { $0["remainingBps"] = 10001 },
            mutateWindow { $0["remainingBps"] = true },
            mutateWindow { $0["availability"] = "unavailable" },
            mutateWindow { $0["currency"] = "USD" },
            mutateWindow { $0["unit"] = "money" },
            mutateWindow { $0["amount"] = "NaN" },
            mutateWindow { $0["observedAt"] = "yesterday" },
            mutateWindow { $0["staleAt"] = "2026-09-01T00:00:00Z" },
            mutateWindow { $0["remainingBps"] = NSNull() },
            mutateWindow { $0["window"] = ["kind": "unknown"] }
        ]
        for (index, data) in invalid.enumerated() { XCTAssertThrowsError(try SnapshotCodec.decode(data), "mutation \(index)") }
        XCTAssertThrowsError(try SnapshotCodec.decode(Data(repeating: 32, count: 32_769)))
    }
    func testMAC01SyntheticScreenGeometry() {
        for (screen, visible, inset) in [
            (CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 70, width: 1512, height: 875), CGFloat(37)),
            (CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: -1920, y: 0, width: 1920, height: 1056), CGFloat(0))
        ] {
            let frame = IslandPlacement.frame(screen: screen, visible: visible, safeAreaTop: inset, size: CGSize(width: 280, height: 52))
            XCTAssertTrue(visible.contains(frame))
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - inset - 8)
            XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 8)
        }
    }
    func testNotchAttachmentKeepsTextWingsOutsideCamera() {
        for origin in [CGFloat(0), -1800] {
            let screen = CGRect(x: origin, y: 0, width: 1800, height: 1169)
            let camera = CGRect(x: origin + 790, y: 1131, width: 220, height: 38)
            let frame = IslandPlacement.notchFrame(screen: screen, camera: camera)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(frame.midX, camera.midX)
            XCTAssertEqual(camera.minX - frame.minX, 112)
            XCTAssertEqual(frame.maxX - camera.maxX, 112)
            XCTAssertTrue(screen.contains(frame))
        }
    }
    func testProviderCatalogUsesStableVisualIdentities() {
        XCTAssertEqual(ProviderCatalog.identity(for: "codex-cli").tone, .teal)
        XCTAssertEqual(ProviderCatalog.identity(for: "openai").displayName, "OpenAI")
        XCTAssertEqual(ProviderCatalog.identity(for: "anthropic").displayName, "Claude")
        XCTAssertEqual(ProviderCatalog.identity(for: "zai").monogram, "G")
        XCTAssertEqual(ProviderCatalog.identity(for: "internal_provider").displayName, "internal_provider")
    }
    func testQuotaWindowUsesHumanReadableShortDisplayNames() throws {
        XCTAssertEqual(try snapshot("01-fresh").windows[0].shortDisplayName, "5小时限额")
        XCTAssertEqual(try snapshot("08-multiple-windows").windows[1].shortDisplayName, "周限额")

        let secondaryWithoutDuration = try mutateWindow { window in
            window["quotaKey"] = "secondary"
            var definition = window["window"] as! [String: Any]
            definition["durationSeconds"] = NSNull()
            window["window"] = definition
        }
        XCTAssertEqual(try SnapshotCodec.decode(secondaryWithoutDuration).windows[0].shortDisplayName, "额度")

        let namedBucket = try mutateWindow { $0["quotaKey"] = "rate_limit-hourly" }
        XCTAssertEqual(try SnapshotCodec.decode(namedBucket).windows[0].shortDisplayName, "额外额度 · 5小时限额")
    }
    func testIslandReducerKeepsDetailsExplicitAndPlacementTopCentered() {
        var state = IslandStateReducer.reduce(.collapsed, .hoverEntered)
        XCTAssertEqual(state, .overview)
        state = IslandStateReducer.reduce(state, .windowSelected("glm-primary"))
        XCTAssertEqual(state, .detail(windowID: "glm-primary"))
        XCTAssertEqual(IslandStateReducer.reduce(state, .hoverExited), .collapsed)
        XCTAssertEqual(IslandStateReducer.reduce(state, .back), .overview)

        let screen = CGRect(x: -1800, y: 0, width: 1800, height: 1169)
        let visible = CGRect(x: -1800, y: 0, width: 1800, height: 1131)
        let metrics = IslandLayoutMetrics.metrics(for: state, cameraSize: CGSize(width: 220, height: 38), availableWidth: visible.width)
        let frame = IslandPlacement.topCenteredFrame(screen: screen, visible: visible, safeAreaTop: 38, size: metrics.size, attachesToScreenTop: true)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY)

        let camera = CGSize(width: 220, height: 38)
        let collapsed = IslandLayoutMetrics.metrics(for: .collapsed, cameraSize: camera, availableWidth: visible.width)
        let overview = IslandLayoutMetrics.metrics(for: .overview, cameraSize: camera, availableWidth: visible.width)
        let detail = IslandLayoutMetrics.metrics(for: .detail(windowID: "glm-primary"), cameraSize: camera, availableWidth: visible.width)
        XCTAssertGreaterThanOrEqual(collapsed.size.width, camera.width + 200)
        XCTAssertGreaterThanOrEqual(collapsed.size.height, camera.height + 4)
        XCTAssertGreaterThan(overview.size.height, collapsed.size.height)
        XCTAssertGreaterThan(detail.size.height, overview.size.height)
        XCTAssertEqual(overview.size.width, detail.size.width)
    }
    func testFractionalFixedWindow() throws {
        let fractional = try mutateWindow {
            var window = $0["window"] as! [String: Any]
            window["startsAt"] = "2026-09-04T23:30:00.123Z"
            window["resetsAt"] = "2026-09-05T04:30:00.123Z"
            $0["window"] = window
        }
        XCTAssertNoThrow(try SnapshotCodec.decode(fractional))
    }
}
