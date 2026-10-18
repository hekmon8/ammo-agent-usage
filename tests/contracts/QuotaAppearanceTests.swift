import Foundation
import XCTest
import SwiftUI
import QuotaCore
@testable import QuotaDesign

final class QuotaAppearanceTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var now: Date { QuotaRules.date("2026-09-05T01:41:00Z")! }

    private func presentation(_ name: String, offline: Bool = false, locked: Bool = false) throws -> QuotaPresentation {
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(name).json"))
        let window = try SnapshotCodec.decode(data).windows[0]
        return QuotaPresentation(window: window, now: now, offline: offline, locked: locked)
    }

    @MainActor
    func testProviderAliasesLoadTheirActualBundledBrandImages() async {
        let families: [(String, [String])] = [
            ("codex", ["codex", "codex-cli", "openai", "azure-openai"]),
            ("claude", ["claude", "anthropic", "claude-code"]),
            ("zai", ["zai", "z.ai", "z-ai", "glm", "zhipu", "zhipuai"]),
            ("gemini", ["gemini", "google-gemini"]),
            ("copilot", ["copilot", "github-copilot"]),
            ("factory", ["factory", "droid", "factory-droid"]),
            ("workbuddy", ["workbuddy", "codebuddy"]),
            ("zcode", ["zcode"]),
            ("fal", ["fal"]),
            ("cloudflare", ["cloudflare"]),
            ("vercel", ["vercel"]),
            ("replit", ["replit"]),
            ("alibaba", ["alibaba", "qwen", "dashscope", "alibaba-coding-plan", "alibaba-token-plan"]),
            ("opencode", ["opencode", "open-code"]),
            ("opencodego", ["opencodego", "opencode-go"]),
            ("openrouter", ["openrouter", "open-router"]),
            ("minimax", ["minimax", "mini-max"]),
            ("kimi", ["kimi", "moonshot", "kimik2", "kimi-k2"]),
            ("qwencloud", ["qwen-cloud"]), ("groq", ["groqcloud"]), ("abacus", ["abacusai"])
        ]
        for (resource, aliases) in families {
            for alias in aliases {
                for input in [alias, " \n" + alias.uppercased() + "\t "] {
                    XCTAssertEqual(ProviderBrandAsset.resourceName(for: input), resource, input)
                    // Calls the production bundle lookup and native image decoder,
                    // so a renamed, omitted or unreadable PNG fails this check.
                    XCTAssertNotNil(ProviderBrandAsset.nativeImage(for: input), input)
                }
            }
        }
    }

    @MainActor
    func testUnknownProvidersKeepLettermarkFallback() async {
        XCTAssertNil(ProviderBrandAsset.nativeImage(for: " future-provider "))
        XCTAssertEqual(ProviderBrandAsset.initial(for: " future-provider "), "F")
        XCTAssertNil(ProviderBrandAsset.nativeImage(for: " \n\t "))
        XCTAssertEqual(ProviderBrandAsset.initial(for: " \n\t "), "?")
    }

    func testFreshSemanticThresholdsAndUnavailableValues() throws {
        for (fixture, expected) in [
            ("01-fresh", QuotaVisualState.normal), ("02-low", .low), ("11-exhausted", .exhausted),
            ("03-stale", .historical), ("04-reset-pending", .historical),
            ("05-unavailable", .unavailable), ("07-auth-required", .historical)
        ] {
            XCTAssertEqual(QuotaVisualState(try presentation(fixture)), expected, fixture)
        }
        XCTAssertEqual(QuotaVisualState(try presentation("02-low", offline: true)), .historical)
        XCTAssertEqual(QuotaVisualState(try presentation("11-exhausted", offline: true)), .historical)
        XCTAssertEqual(QuotaVisualState(try presentation("02-low", offline: true, locked: true)), .unavailable)
        XCTAssertNil(QuotaEdgeMotionPolicy.progress(for: try presentation("05-unavailable")))
        XCTAssertEqual(QuotaEdgeMotionPolicy.progress(for: try presentation("11-exhausted")), 0)
        XCTAssertEqual(QuotaEdgeMotionPolicy.progress(for: try presentation("01-fresh")), 0.68)
        XCTAssertNil(QuotaEdgeMotionPolicy.progress(for: try presentation("09-money")))
    }

    func testFailedLowObservationNeverBecomesFreshWarning() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/02-low.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var windows = object["windows"] as! [[String: Any]]
        windows[0]["fetchOutcome"] = "error"
        object["windows"] = windows
        let snapshot = try SnapshotCodec.decode(JSONSerialization.data(withJSONObject: object))
        let value = QuotaPresentation(window: snapshot.windows[0], now: now)
        XCTAssertEqual(QuotaVisualState(value), .historical)
        XCTAssertFalse(QuotaEdgeMotionPolicy.permitsAmbientMotion(value: value, style: .calibrated, enabled: true, reduceMotion: false, lowPower: false))
    }

    func testAmbientPolicyHonorsAllSuppressionInputs() throws {
        let normal = try presentation("01-fresh")
        XCTAssertTrue(QuotaEdgeMotionPolicy.permitsAmbientMotion(value: normal, style: .calibrated, enabled: true, reduceMotion: false, lowPower: false))
        for style in QuotaDisplayStyle.allCases {
            for enabled in [true, false] {
                for reduce in [true, false] {
                    for lowPower in [true, false] {
                        XCTAssertEqual(QuotaEdgeMotionPolicy.permitsAmbientMotion(value: normal, style: style, enabled: enabled, reduceMotion: reduce, lowPower: lowPower),
                                       style == .calibrated && enabled && !reduce && !lowPower)
                    }
                }
            }
        }
        for fixture in ["03-stale", "04-reset-pending", "05-unavailable", "06-unlimited", "07-auth-required", "09-money", "11-exhausted"] {
            XCTAssertFalse(QuotaEdgeMotionPolicy.permitsAmbientMotion(value: try presentation(fixture), style: .calibrated, enabled: true, reduceMotion: false, lowPower: false), fixture)
        }
    }

    func testExistingActivityOptionsDecodeWithoutResettingChoices() throws {
        let old = Data(#"{"showWindowName":false,"showProgress":false,"showObservationTime":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ActivityDisplayOptions.self, from: old)
        XCTAssertFalse(decoded.showWindowName)
        XCTAssertFalse(decoded.showProgress)
        XCTAssertTrue(decoded.showObservationTime)
        XCTAssertEqual(decoded.displayStyle, .calibrated)
        XCTAssertEqual(decoded.compactStyle, .ring)
        for style in ActivityCompactStyle.allCases {
            let options = ActivityDisplayOptions(compactStyle: style)
            XCTAssertEqual(try JSONDecoder().decode(ActivityDisplayOptions.self, from: JSONEncoder().encode(options)), options)
        }
        XCTAssertEqual(try JSONDecoder().decode(ActivityDisplayOptions.self, from: Data(#"{"compactStyle":"future"}"#.utf8)).compactStyle, .ring)
        for style in QuotaDisplayStyle.allCases {
            let value = ActivityDisplayOptions(showWindowName: false, showProgress: true, showObservationTime: false, displayStyle: style)
            XCTAssertEqual(try JSONDecoder().decode(ActivityDisplayOptions.self, from: JSONEncoder().encode(value)), value)
        }
        let future = Data(#"{"displayStyle":"future-style","showProgress":false}"#.utf8)
        let fallback = try JSONDecoder().decode(ActivityDisplayOptions.self, from: future)
        XCTAssertEqual(fallback.displayStyle, .calibrated)
        XCTAssertFalse(fallback.showProgress)
    }

    func testDisplayChoiceRoundTripsThroughDevicePreferences() throws {
        let suite = "QuotaAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(QuotaDisplayStyle(storedValue: defaults.string(forKey: QuotaAppearanceKeys.displayStyle) ?? ""), .calibrated)
        for style in QuotaDisplayStyle.allCases {
            defaults.set(style.rawValue, forKey: QuotaAppearanceKeys.displayStyle)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(QuotaDisplayStyle(storedValue: reopened.string(forKey: QuotaAppearanceKeys.displayStyle) ?? ""), style)
        }
        defaults.set("unrecognized", forKey: QuotaAppearanceKeys.displayStyle)
        XCTAssertEqual(QuotaDisplayStyle(storedValue: defaults.string(forKey: QuotaAppearanceKeys.displayStyle)!), .calibrated)
    }

    func testNotchedBoundaryHasNoStrokeAcrossCameraEdge() {
        let rect = CGRect(x: 0, y: 0, width: 440, height: 66)
        let path = QuotaBoundaryShape(attachesToTop: true).path(in: rect)
        var topEndpoints = [CGPoint]()
        var closes = false
        path.forEach { element in
            switch element {
            case .move(let point), .line(let point): if point.y == 0 { topEndpoints.append(point) }
            case .closeSubpath: closes = true
            default: break
            }
        }
        XCTAssertEqual(topEndpoints, [CGPoint(x: 1.5, y: 0), CGPoint(x: 438.5, y: 0)])
        XCTAssertFalse(closes, "Closing a U-shaped path would draw across the hardware notch")
        XCTAssertTrue(rect.contains(path.boundingRect))
    }
}
