import XCTest
import SwiftUI
@testable import AmmoMac

final class BillingCardLayoutTests: XCTestCase {
    func testShortCardsFillSpaceBesideTallCardInsteadOfWaitingForItsRow() {
        let frames = BillingCardLayout.frames(width: 728, heights: [130, 374, 130, 180, 130])
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 356, height: 130),
            CGRect(x: 372, y: 0, width: 356, height: 374),
            CGRect(x: 0, y: 146, width: 356, height: 130),
            CGRect(x: 0, y: 292, width: 356, height: 180),
            CGRect(x: 372, y: 390, width: 356, height: 130),
        ])
    }

    func testColumnBreakpointsAndSingleColumnOrder() {
        for (width, columns) in [(615.0, 1), (616.0, 2), (931.0, 2), (932.0, 3)] {
            XCTAssertEqual(BillingCardLayout.columnCount(width: width), columns)
        }
        let frames = BillingCardLayout.frames(width: 567, heights: [130, 374, 180])
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 567, height: 130),
            CGRect(x: 0, y: 146, width: 567, height: 374),
            CGRect(x: 0, y: 536, width: 567, height: 180),
        ])
        XCTAssertTrue(BillingCardLayout.frames(width: 728, heights: []).isEmpty)
    }

    func testRepackingAfterFilteringOrTextHeightChanges() {
        let original = BillingCardLayout.frames(width: 616, heights: [130, 130, 80])
        XCTAssertEqual(original[2].origin, CGPoint(x: 0, y: 146))
        let wrapped = BillingCardLayout.frames(width: 616, heights: [160, 130, 80])
        XCTAssertEqual(wrapped[2].origin, CGPoint(x: 316, y: 146))
        let filtered = BillingCardLayout.frames(width: 616, heights: [130, 80])
        XCTAssertEqual(filtered[1].origin, CGPoint(x: 316, y: 0))
    }
}
