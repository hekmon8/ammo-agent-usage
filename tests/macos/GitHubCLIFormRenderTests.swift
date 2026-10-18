import AppKit
import SwiftUI
import XCTest
import QuotaCore
import QuotaDesign
@testable import AmmoMac

/// Actual hosted native form, synthetic model; no restore, login, collector or sync.
final class GitHubCLIFormRenderTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/github-cli-previews")
    }
    @MainActor
    func testDefaultCLIAndIdentityFailureFormInBothLanguages() throws {
        _ = NSApplication.shared
        let language = L10n.currentSetting
        defer { L10n.setLanguage(language) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GitHubCLIFormRenderTests-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        for (language, code) in [(QuotaLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            L10n.setLanguage(language)
            model.providerConnectionError = LocalizedStatus.empty
            try renderHosted(AddProviderAccountView(fixtureMode: true, model: model, selectedProvider: "github-actions"),
                filename: "github-cli-default-\(code).png", size: CGSize(width: 680, height: 600))
            try renderHosted(AddProviderAccountView(fixtureMode: true, model: model, selectedProvider: "github-actions", initialLocalAmbient: false),
                filename: "github-cli-manual-\(code).png", size: CGSize(width: 680, height: 600))
            model.providerConnectionError = LocalizedStatus("billing.github.identityUnavailable")
            try renderHosted(AddProviderAccountView(fixtureMode: true, model: model, selectedProvider: "github-actions"),
                filename: "github-cli-identity-error-\(code).png", size: CGSize(width: 680, height: 600))
            XCTAssertFalse(model.connecting)
            XCTAssertNil(model.snapshot)
        }
    }
    @MainActor
    func testRealFormInitializationPreservesReconnectMethodAndOrganization() throws {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GitHubCLIReconnect-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        for ambient in [false, true] {
            var observed: (Bool, String)?
            try renderHosted(AddProviderAccountView(model: model, selectedProvider: "github-actions",
                replacingConnectionID: "synthetic", initialLocalAmbient: ambient,
                initialOrganization: "demo-org", onFormState: { method, organization, _ in observed = (method, organization) }),
                filename: "github-cli-reconnect-\(ambient).png", size: CGSize(width: 680, height: 600))
            XCTAssertEqual(observed?.0, ambient)
            XCTAssertEqual(observed?.1, "demo-org")
        }
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connecting)
    }
    @MainActor
    func testUnavailableLegacyScopeCannotSilentlyConnectToPersonalBilling() throws {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GitHubCLIScopeUnavailable-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        var observed: (Bool, String, Bool)?
        try renderHosted(AddProviderAccountView(model: model, selectedProvider: "github-actions",
            replacingConnectionID: "legacy-synthetic", initialLocalAmbient: true,
            initialScopeUnavailable: true, onFormState: { observed = ($0, $1, $2) }),
            filename: "github-cli-unavailable-scope.png", size: CGSize(width: 680, height: 600))
        XCTAssertEqual(observed?.0, true)
        XCTAssertEqual(observed?.1, "")
        XCTAssertEqual(observed?.2, false)
        XCTAssertFalse(model.connecting)
        XCTAssertNil(model.snapshot)
    }
    @MainActor
    func testScopeConfirmationGateSurvivesSameIdentityReconstruction() throws {
        _ = NSApplication.shared
        let language = L10n.currentSetting
        L10n.setLanguage(.english)
        defer { L10n.setLanguage(language) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GitHubScopeRecompute-" + UUID().uuidString))
        let model = MacModel(tokenUsageDefaults: defaults)
        var observed: (Bool, String, Bool)?
        let observer: (Bool, String, Bool) -> Void = { observed = ($0, $1, $2) }
        let hosting = NSHostingView(rootView: AddProviderAccountView(model: model,
            selectedProvider: "github-actions", replacingConnectionID: "legacy",
            initialLocalAmbient: true, initialScopeUnavailable: true, onFormState: observer))
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() {
            for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        settle()
        XCTAssertEqual(observed?.2, false)
        hosting.rootView = AddProviderAccountView(model: model,
            selectedProvider: "github-actions", replacingConnectionID: "legacy",
            initialLocalAmbient: true, initialOrganization: "demo-org", initialScopeUnavailable: false,
            onFormState: observer)
        settle()
        // Observe the mounted form after a published update, using the actual
        // organization and canConnect values that drive the verification button.
        model.connecting = true; settle()
        observed = nil
        model.connecting = false; settle()
        XCTAssertEqual(observed?.1, "")
        XCTAssertEqual(observed?.2, false)

    }
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
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4096)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent(filename))
    }

}
