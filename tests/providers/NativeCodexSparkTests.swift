import Foundation
import QuotaCore
@testable import QuotaProviders
import XCTest

final class NativeCodexSparkNormalizerTests: XCTestCase {
    func testSparkLabelsPreserveExistingWindowIdentity() throws {
        let data = Data(#"""
        {
          "rateLimits": null,
          "rateLimitsByLimitId": {
            "codex_bengalfox": {
              "limitId": "opaque-preview-id",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {"usedPercent": 12, "windowDurationMins": 300},
              "secondary": {"usedPercent": 34, "windowDurationMins": 10080}
            }
          }
        }
        """#.utf8)

        let windows = try CodexNormalizer.normalize(
            data, accountID: "account", alias: "Codex", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(windows.map(\.quotaKey), ["codex_bengalfox-primary", "codex_bengalfox-secondary"])
        XCTAssertEqual(windows.map(\.id), ["codex-codex_bengalfox-primary", "codex-codex_bengalfox-secondary"])
        XCTAssertTrue(windows.allSatisfy { $0.shortDisplayName.hasPrefix("Spark") })
        XCTAssertEqual(windows.map(\.window.durationSeconds), [18_000, 604_800])
    }

    func testPresentationMetadataNeverChangesStoredIdentifiers() throws {
        let data = Data(#"""
        {
          "rateLimitsByLimitId": {
            "opaque": {
              "rate_limit_name": "codex spark preview",
              "primary": {"usedPercent": 1, "windowDurationMins": 300}
            }
          }
        }
        """#.utf8)
        let windows = try CodexNormalizer.normalize(data, accountID: "account", alias: "Codex", now: .now)
        XCTAssertEqual(windows.map(\.quotaKey), ["opaque-primary"])
        XCTAssertEqual(windows.map(\.id), ["codex-opaque-primary"])
    }

    func testOpaqueBengalfoxKeyWithoutMetadataStaysLegacyCompatible() throws {
        let data = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex_bengalfox": {
              "primary": {"usedPercent": 1, "windowDurationMins": 300}
            }
          }
        }
        """#.utf8)
        let windows = try CodexNormalizer.normalize(data, accountID: "account", alias: "Codex", now: .now)
        XCTAssertEqual(windows.map(\.quotaKey), ["codex_bengalfox-primary"])
    }
}
