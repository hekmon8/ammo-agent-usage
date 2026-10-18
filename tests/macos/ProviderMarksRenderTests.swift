import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign
@testable import AmmoMac

final class ProviderMarksRenderTests: XCTestCase {
    @MainActor
    func testActualIslandSelectorRendersZCodeAndSeparateAccounts() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/01-fresh.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let original = try XCTUnwrap((object["windows"] as? [[String: Any]])?.first)
        // Two OpenRouter accounts intentionally keep separate selector buttons.
        let providers = ["claude", "fal", "grok", "openrouter", "openrouter", "workbuddy", "zai", "zcode"]
        object["windows"] = providers.enumerated().map { index, provider in
            var window = original
            window["id"] = "synthetic-mark-\(index)"
            window["providerId"] = provider
            window["accountId"] = "synthetic-account-\(index)"
            window["accountAlias"] = "Synthetic \(index)"
            return window
        }
        let snapshot = try SnapshotCodec.decode(JSONSerialization.data(withJSONObject: object))
        let now = try XCTUnwrap(QuotaRules.date(snapshot.capturedAt))
        let values = snapshot.windows.map { QuotaPresentation(window: $0, now: now) }
        let groups = QuotaAccountGroup.grouped(values)
        XCTAssertEqual(groups.count, 8)
        XCTAssertEqual(groups.filter { $0.providerID == "openrouter" }.count, 2)
        let selected = try XCTUnwrap(groups.first { $0.providerID == "zcode" })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProviderMarksRender-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        let content = MacStudioIslandContent(model: model, fixture: values, state: .overview,
            cameraSize: nil, onHover: { _ in }, onSelectIsland: {}, onSelectWindow: { _ in },
            onBack: {}, onCollapse: {}, selectedAccountID: selected.id, animationEnabled: false)
            .frame(width: 640, height: 350).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 350)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = root.appendingPathComponent(".build/provider-marks-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("island-zcode-selected-dark.png"))
        XCTAssertGreaterThan(png.count, 1_000, "Retain a nonempty preview for visual verification")
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connecting)
    }
}
