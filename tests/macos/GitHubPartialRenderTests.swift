import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign
@testable import QuotaProviders
@testable import AmmoMac

final class GitHubPartialRenderTests: XCTestCase {
    @MainActor
    func testActualDetailsRenderBothIndependentPartialStatesAndAllUnknown() async throws {
        _ = NSApplication.shared
        let originalLanguage = L10n.currentSetting
        defer { L10n.setLanguage(originalLanguage) }
        let now = QuotaRules.date("2026-10-08T00:00:00Z")!
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/github-partial-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GitHubPartialRender-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        let connection = ProviderConnectionSummary(id: "synthetic", providerID: "github-actions", displayName: "GitHub Actions",
            accountAlias: "Synthetic", methodKind: .githubCLILogin, statusKind: .updateIncomplete, isEnabled: false)
        for (expenseAvailable, budgetAvailable) in [(false, true), (true, false), (false, false)] {
            let report = try await GitHubBillingReader.load(organization: "demo-org", now: now, includeBudgets: true, headers: [:]) { url, _ in
                if url.path == "/user" { return Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8) }
                if url.path == "/orgs/demo-org" { return Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8) }
                if url.path.hasSuffix("budgets") {
                    guard budgetAvailable else { throw ProviderFailure.permissionDenied }
                    return Data(#"{"budgets":[{"id":"synthetic","budget_type":"ProductPricing","budget_scope":"organization","budget_product_skus":["actions"],"budget_amount":100,"prevent_further_usage":true}],"has_next_page":false,"total_count":1}"#.utf8)
                }
                guard expenseAvailable else { throw ProviderFailure.unsupported }
                return Data(#"{"timePeriod":{"year":2026,"month":10},"organization":"demo-org","usageItems":[{"product":"Actions","sku":"runner","unitType":"minutes","netAmount":8}]}"#.utf8)
            }
            XCTAssertEqual(report.usage.cost != nil, expenseAvailable)
            XCTAssertEqual(report.budgetState == .available, budgetAvailable)
            for (language, code) in [(QuotaLanguage.simplifiedChinese, "zh"), (.english, "en")] {
                L10n.setLanguage(language)
                let content = GitHubBillingDetailsView(model: model, connection: connection, initialReport: report)
                    .background(PaperInk(.light).canvas).environment(\.colorScheme, .light)
                try renderHosted(content, directory: directory,
                    filename: "expense-\(expenseAvailable)-budgets-\(budgetAvailable)-\(code)")
            }
        }
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connecting)
    }

    @MainActor
    private func renderHosted<Content: View>(_ content: Content, directory: URL, filename: String) throws {
        let size = CGSize(width: 580, height: 620)
        let hosting = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: L10n.effectiveLanguageCode)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func display() {
            for _ in 0..<4 {
                hosting.needsLayout = true
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        func capture(_ suffix: String) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1160, pixelsHigh: 1240,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var darkBodyPixels = 0
            for y in stride(from: 350, to: 1000, by: 4) {
                for x in stride(from: 40, to: 1120, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent < 0.55, color.greenComponent < 0.55, color.blueComponent < 0.55 {
                        darkBodyPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(darkBodyPixels, 100, "A header-only image must not pass as rendered billing data")
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(filename + suffix + ".png"))
        }
        display()
        try capture("")
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(hosting), "The actual billing details must have a native scroll view")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        display()
        try capture("-bottom")
    }
}
