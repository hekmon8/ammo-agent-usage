import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign

/// Synthetic native shared-card renders only; no model restore, login or sync.
final class GitHubBillingRenderTests: XCTestCase {
    @MainActor
    func testNativeCardAndDetailsInBothLanguagesKeepUnknownsVisible() throws {
        let language = L10n.currentSetting
        defer { L10n.setLanguage(language) }
        let now = QuotaRules.date("2026-10-07T12:00:00Z")!
        let window = QuotaWindow.providerValue(id: "synthetic-github", providerID: "github-actions",
            accountID: "synthetic", alias: "Demo", key: "cost-spend", unit: .money, currency: "USD",
            remainingBps: nil, amount: "8", limit: nil, quality: .reported, source: .officialAPI,
            observedAt: now, staleAt: now.addingTimeInterval(600), windowKind: .calendar, duration: nil,
            resetsAt: nil, startsAt: QuotaRules.date("2026-10-01T00:00:00Z"), periodID: "github-actions-user-2026-10")
        let value = QuotaPresentation(window: window, now: now)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/github-billing-previews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (language, code) in [(QuotaLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            L10n.setLanguage(language)
            XCTAssertEqual(GitHubActionsReporting.queryMonth(window), "2026-10")
            XCTAssertFalse(L("billing.github.cardUnknown").contains("billing.github.cardUnknown"))
            let content = VStack(alignment: .leading, spacing: 24) {
                Text("GitHub Actions · Demo").font(.headline)
                BillingMetricRow(value: value, showsAccount: false, compact: true)
                Divider()
                BillingMetricDetails(value: value)
            }.padding(24).frame(width: 460, height: 900, alignment: .topLeading)
                .background(PaperInk(.light).canvas).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 920)
            XCTAssertEqual(image.height, 1800)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 4096)
            try data.write(to: root.appendingPathComponent("github-actions-\(code)-synthetic-macos.png"))
        }
    }
}
