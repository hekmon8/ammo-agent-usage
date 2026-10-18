import XCTest
import Foundation
import QuotaCore
import QuotaProviders

final class ClaudeNormalizerTests: XCTestCase {
    func testQuotaDoesNotUseContextOccupancyOrInventAbsoluteUnits() throws {
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1788579000}},"context_window":{"remaining_percentage":1},"transcript_path":"ignored-private-path"}"#.utf8)
        let observed = Date(timeIntervalSince1970: 1788572460)
        let windows = try ClaudeNormalizer.normalize(input, accountID: "synthetic-claude", observedAt: observed)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].remainingBps, 7650)
        XCTAssertNil(windows[0].amount)
        XCTAssertEqual(QuotaPresentation(window: windows[0], now: observed.addingTimeInterval(601)).state, .stale)
    }
    func testMissingOrInvalidLimitsRemainUnknown() {
        for input in [#"{"context_window":{"remaining_percentage":99}}"#, #"{"rate_limits":{}}"#, #"{"rate_limits":{"five_hour":{"used_percentage":101}}}"#] {
            XCTAssertThrowsError(try ClaudeNormalizer.normalize(Data(input.utf8), accountID: "synthetic", observedAt: .now))
        }
    }
}
