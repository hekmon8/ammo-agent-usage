import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign
@testable import AmmoMac

/// Hosted connection sheet only. No agy process, keychain, or network.
final class AntigravityFormRenderTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/antigravity-previews")
    }

    @MainActor
    func testLocalLoginNeedsNoTokenAndManualImportStillRequiresOne() throws {
        _ = NSApplication.shared
        let language = L10n.currentSetting
        defer { L10n.setLanguage(language) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AntigravityFormRender-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        for (language, code) in [(QuotaLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            L10n.setLanguage(language)
            for ambient in [true, false] {
                var observed: (Bool, Bool)?
                let view = AddProviderAccountView(model: model, selectedProvider: "antigravity",
                    initialLocalAmbient: ambient, onFormState: { observed = ($0, $2) })
                try render(view, filename: "antigravity-\(ambient ? "local" : "manual")-\(code).png")
                XCTAssertEqual(observed?.0, ambient)
                XCTAssertEqual(observed?.1, ambient, "Local needs no pasted token; manual must require one")
            }
        }
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connecting)
    }

    @MainActor
    private func render<Content: View>(_ content: Content, filename: String) throws {
        let size = CGSize(width: 680, height: 600)
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(PaperInk(.light).canvas).environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: L10n.effectiveLanguageCode)).tint(PaperInk(.light).accent))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<6 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1360, pixelsHigh: 1200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try image.write(to: outputDirectory.appendingPathComponent(filename))
    }
}
