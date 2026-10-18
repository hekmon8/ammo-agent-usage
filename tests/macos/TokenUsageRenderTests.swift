import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign
import QuotaPhone
@testable import AmmoMac

#if DEBUG

/// Native SwiftUI QA artifacts, generated only from the synthetic factory below.
/// These tests do not call model.restore(), scan logs, read provider credentials,
/// start collection, connect a sync service or exercise export permissions.
final class TokenUsageRenderTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/token-usage-previews", isDirectory: true)
    }

    @MainActor
    func testRenderNativeMacAndPhoneUsageWithSyntheticData() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentSetting
        L10n.setLanguage(.simplifiedChinese)
        defer { L10n.setLanguage(previousLanguage) }
        let now = Date()
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let snapshot = syntheticSnapshot(period: .week, anchor: now, zone: zone)
        let model = MacModel.preview(tokenUsage: snapshot)
        XCTAssertTrue(model.tokenUsageEnabled)
        XCTAssertFalse(model.tokenUsageBusy)
        XCTAssertEqual(model.tokenUsage?.sourceDeviceId, "SYNTHETIC_RENDER_ONLY")

        try renderHosted(TokenUsageView(model: model), filename: "mac-usage-zh.png",
                   size: CGSize(width: 1160, height: 1020))
        // This is the production QuotaPhone view, rendered at phone width by
        // macOS SwiftUI. The artifact is labelled accordingly; it does not claim
        // to be an iOS simulator screenshot or test native Photos/share sheets.
        try renderHosted(TokenUsagePhoneView(snapshot: snapshot), filename: "phone-usage-zh-macos-layout.png",
                   size: CGSize(width: 393, height: 1100))
        try writeArtifactNotes()
    }

    @MainActor
    func testRenderLocalCostCoverageAndResetSettings() throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentSetting
        defer { L10n.setLanguage(previousLanguage) }
        L10n.setLanguage(.simplifiedChinese)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date()
        let day = TokenUsageCalendar.day(now, in: zone)
        let analysis = TokenUsageLocalAnalysis(capturedAt: ISO8601DateFormatter().string(from: now), timeZoneIdentifier: zone.identifier,
            sources: [TokenUsageScanCoverage(agent: .codex, discoveredFiles: 1553, readFiles: 1553,
                bytesRead: 6_953_778_817, byteLimit: 8_589_934_592,
                reasons: ["oversized_lines": 367, "unreconciled_legacy_rows": 120])],
            costs: [TokenUsageCostBucket(day: day, agent: .codex, standardUSD: 18.42,
                pricedTokens: 6_000_000, unpricedTokens: 2_000_000)])
        let coordinator = ResetReminderCoordinator(storage: VolatileResetReminderStorage())
        let content = VStack(alignment: .leading, spacing: 20) {
            TokenUsageLocalAnalysisView(analysis: analysis, period: .day, anchor: now, timeZone: zone, stale: true)
            ResetReminderSettingsView(coordinator: coordinator)
        }.padding(24)
        try renderHosted(content, filename: "mac-cost-reminders-zh.png", size: CGSize(width: 720, height: 680))
    }

    @MainActor
    func testRenderPhoneProviderCardsAndCompactNavigation() throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentSetting
        defer { L10n.setLanguage(previousLanguage) }
        L10n.setLanguage(.simplifiedChinese)
        let now = Date()
        let values = ["claude", "codex"].flatMap { provider in
            [18_000, 604_800].enumerated().map { index, duration in
                QuotaPresentation(window: .reported(id: provider + "-" + String(index), providerID: provider,
                    accountID: "SYNTHETIC_UX", alias: "演示账号", key: index == 0 ? "primary" : "secondary",
                    remainingBps: index == 0 ? 6_800 : 4_200, observedAt: now,
                    staleAt: now.addingTimeInterval(600), duration: duration,
                    resetsAt: now.addingTimeInterval(Double(duration)), source: .userDefined), now: now)
            }
        }
        let content = VStack(spacing: 0) {
            ScrollView { QuotaPhoneView(values: values, now: now) }
            PhoneSectionBar(selected: .overview) { _ in }
        }
        try renderHosted(content, filename: "phone-provider-cards-zh-macos-layout.png", size: CGSize(width: 393, height: 1000))
        try renderHosted(content, filename: "phone-provider-cards-dark-zh-macos-layout.png", size: CGSize(width: 393, height: 1000), scheme: .dark)
        try renderHosted(content, filename: "phone-provider-cards-accessible-zh-macos-layout.png", size: CGSize(width: 393, height: 1200), sizeCategory: .accessibilityExtraLarge)
        for selected in PhoneSection.allCases {
            try renderHosted(PhoneSectionBar(selected: selected) { _ in }, filename: "phone-tab-\(selected)-zh-macos-layout.png", size: CGSize(width: 393, height: 90))
        }
    }

    @MainActor
    func testRenderReceiptWithOneToolOutsideThePeriod() throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentSetting
        defer { L10n.setLanguage(previousLanguage) }
        L10n.setLanguage(.simplifiedChinese)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let anchor = try XCTUnwrap(QuotaRules.date("2026-10-07T12:00:00Z"))
        let base = syntheticSnapshot(period: .week, anchor: anchor, zone: zone)
        let snapshot = TokenUsageSnapshot(sourceDeviceId: base.sourceDeviceId, sourceEpoch: base.sourceEpoch,
            sourceSequence: 1, capturedAt: base.capturedAt, timeZoneIdentifier: zone.identifier,
            retainedFromDay: base.retainedFromDay, sources: base.sources,
            buckets: base.buckets.filter { $0.agent == .claudeCode })
        let summary = TokenUsageSummary.make(snapshot: snapshot, period: .week, anchor: anchor, timeZone: zone)
        XCTAssertEqual(summary.byAgent[.codex], .zero)
        XCTAssertFalse(TokenUsageText.hasRecords(.codex, summary: summary))
        XCTAssertTrue(TokenUsageText.hasRecords(.claudeCode, summary: summary))
        try renderReceipt(TokenUsageReceiptData(snapshot: snapshot, summary: summary, period: .week), filename: "receipt-no-codex-period-zh.png")
    }

    @MainActor
    func testRenderReceiptLanguagesAndStaleMonthEdge() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentSetting
        defer { L10n.setLanguage(previousLanguage) }
        let weekZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let weekAnchor = try XCTUnwrap(QuotaRules.date("2026-09-27T12:00:00Z"))
        let week = syntheticSnapshot(period: .week, anchor: weekAnchor, zone: weekZone)
        let summary = TokenUsageSummary.make(snapshot: week, period: .week, anchor: weekAnchor, timeZone: weekZone)
        XCTAssertNotNil(summary.total)
        let receipt = TokenUsageReceiptData(snapshot: week, summary: summary, period: .week)

        L10n.setLanguage(.simplifiedChinese)
        try renderReceipt(receipt, filename: "receipt-week-zh.png")
        L10n.setLanguage(.english)
        try renderReceipt(receipt, filename: "receipt-week-en.png")

        // Thirty-one columns, DST boundary, large totals and the extra stale line
        // stress the fixed receipt canvas rather than testing only a short week.
        let monthZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let monthAnchor = try XCTUnwrap(QuotaRules.date("2026-10-31T12:00:00Z"))
        let month = syntheticSnapshot(period: .month, anchor: monthAnchor, zone: monthZone, multiplier: 500)
        let monthSummary = TokenUsageSummary.make(snapshot: month, period: .month, anchor: monthAnchor, timeZone: monthZone)
        XCTAssertEqual(Set(monthSummary.daily.map(\.day)).count, 31)
        try renderReceipt(TokenUsageReceiptData(snapshot: month, summary: monthSummary, period: .month, stale: true),
                          filename: "receipt-month-stale-en.png")
        try writeArtifactNotes()
    }

    @MainActor
    private func renderReceipt(_ data: TokenUsageReceiptData, filename: String) throws {
        // Mirror the app exporters exactly: fixed 540 × 980 point view at 2x.
        XCTAssertEqual(TokenUsageReceiptView.width, 540)
        XCTAssertEqual(TokenUsageReceiptView.height, 980)
        let projection = String(reflecting: data)
        XCTAssertFalse(projection.contains("SYNTHETIC_RENDER_ONLY"))
        XCTAssertFalse(projection.contains("SYNTHETIC_EPOCH"))
        XCTAssertFalse(projection.contains("synthetic_marker"))
        try render(TokenUsageReceiptView(data: data), filename: filename,
                   size: CGSize(width: TokenUsageReceiptView.width, height: TokenUsageReceiptView.height))
    }

    /// ImageRenderer intentionally omits NSView-backed controls and scroll views.
    /// Capture a real hosted window for full screens; receipts use ImageRenderer below.
    @MainActor
    private func renderHosted<Content: View>(_ content: Content, filename: String, size: CGSize, scheme: ColorScheme = .light, sizeCategory: ContentSizeCategory = .medium) throws {
        let view = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(PaperInk(scheme).canvas)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: L10n.effectiveLanguageCode))
            .environment(\.sizeCategory, sizeCategory)
            .tint(PaperInk(scheme).accent)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        // The temporary QA window has to join the native rendering lifecycle.
        // Keep it outside the desktop so tests do not obscure other runner windows.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Synchronous helper deliberately drains AppKit layout/display work.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        // Point size is independent of bitmap pixels: explicitly capture at 2x,
        // even when the CI runner's virtual display has a 1x backing scale.
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try saveAndValidate(bitmap, filename: filename, size: size)
    }

    @MainActor
    private func render<Content: View>(_ content: Content, filename: String, size: CGSize) throws {
        let view = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(PaperInk(.light).canvas)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: L10n.effectiveLanguageCode))
            .environment(\.sizeCategory, .medium)
            .tint(PaperInk(.light).accent)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer did not produce \(filename)")
        XCTAssertEqual(image.width, Int(size.width * 2), filename)
        XCTAssertEqual(image.height, Int(size.height * 2), filename)
        try saveAndValidate(NSBitmapImageRep(cgImage: image), filename: filename, size: size)
    }

    @MainActor
    private func saveAndValidate(_ bitmap: NSBitmapImageRep, filename: String, size: CGSize) throws {
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * 2), filename)
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * 2), filename)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 4_096, "Unexpectedly empty image: \(filename)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appendingPathComponent(filename)
        try png.write(to: destination, options: .atomic)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        XCTAssertEqual(decoded.pixelsWide, bitmap.pixelsWide)
        XCTAssertEqual(decoded.pixelsHigh, bitmap.pixelsHigh)
        // PNG size alone accepts a large blank canvas. Require varied colors AND
        // a meaningful number of dark content samples across a regular 100×100 grid.
        var colors = Set<Int>()
        var darkSamples = 0
        var samples = 0
        for y in stride(from: 0, to: decoded.pixelsHigh, by: max(1, decoded.pixelsHigh / 100)) {
            for x in stride(from: 0, to: decoded.pixelsWide, by: max(1, decoded.pixelsWide / 100)) {
                guard let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                samples += 1
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                colors.insert((Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31))
                if max(r, g, b) < 0.7 { darkSamples += 1 }
            }
        }
        XCTAssertGreaterThan(colors.count, 12, "Solid or near-solid canvas: \(filename)")
        XCTAssertGreaterThan(darkSamples, max(20, samples / 200), "Missing meaningful foreground content: \(filename)")
    }

    private func syntheticSnapshot(period: TokenUsagePeriod, anchor: Date, zone: TimeZone, multiplier: Int64 = 1) -> TokenUsageSnapshot {
        let calendar = TokenUsageCalendar.calendar(in: zone)
        let interval = TokenUsageCalendar.interval(period, anchor: anchor, in: zone)
        var buckets: [TokenUsageBucket] = []
        var date = interval.start
        var index = 0
        while date < interval.end {
            let day = TokenUsageCalendar.day(date, in: zone)
            let variation = Int64([3, 6, 9, 4, 8, 7, 5][index % 7]) * multiplier
            buckets.append(.init(day: day, agent: .codex,
                                 tokens: .init(nonCachedInput: variation * 12_000, cacheRead: variation * 36_000,
                                               cacheWrite: 0, output: variation * 8_000)))
            buckets.append(.init(day: day, agent: .claudeCode,
                                 tokens: .init(nonCachedInput: variation * 6_000, cacheRead: variation * 20_000,
                                               cacheWrite: variation * 2_000, output: variation * 4_000)))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
            index += 1
        }
        let capturedAt = ISO8601DateFormatter().string(from: anchor)
        return TokenUsageSnapshot(
            sourceDeviceId: "SYNTHETIC_RENDER_ONLY", sourceEpoch: "SYNTHETIC_EPOCH", sourceSequence: 1,
            capturedAt: capturedAt, timeZoneIdentifier: zone.identifier, retainedFromDay: "2020-01-01",
            sources: [
                .init(agent: .codex, status: .available, scannedAt: capturedAt, latestEventAt: capturedAt),
                .init(agent: .claudeCode, status: .partial, scannedAt: capturedAt, latestEventAt: capturedAt,
                      diagnostic: "synthetic_marker")
            ], buckets: buckets
        )
    }

    private func writeArtifactNotes() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let notes = """
        Synthetic native SwiftUI rendering QA

        Every PNG in this directory is produced by TokenUsageRenderTests from numeric
        synthetic aggregates created inside that test. No local logs, account IDs,
        projects, conversations, credentials or real user usage are inputs.

        mac-usage-zh.png: production Mac TokenUsageView, 1160 × 1020 pt at 2x,
          captured from NSHostingView in a temporary NSWindow using cacheDisplay.
        phone-usage-zh-macos-layout.png: production QuotaPhone.TokenUsagePhoneView,
          phone-width 393 × 1100 pt at 2x, captured from a native Mac hosting window.
          AppKit controls are included, unlike ImageRenderer. This is NOT an iOS
          simulator/device screenshot and does not validate Photos or share sheets.
        receipt-week-zh.png / receipt-week-en.png: production TokenUsageReceiptView,
          synthetic Monday–Sunday week, 1080 × 1960 px, Chinese / English.
        receipt-month-stale-en.png: production receipt, 31-day month containing a
          daylight-saving transition, large totals and stale warning, 1080 × 1960 px.

        Receipts still use the production ImageRenderer path. Full-screen captures
        explicitly use a 2x bitmap, independent of the runner's native backing scale.
        PNG dimensions, successful decode, size, color variation and dark foreground
        coverage are asserted, so a solid-color canvas cannot pass as a valid screen.
        Human visual inspection is still required to judge clipping, layout and style.
        """
        try Data(notes.utf8).write(to: outputDirectory.appendingPathComponent("README.txt"), options: .atomic)
    }
}

#endif
