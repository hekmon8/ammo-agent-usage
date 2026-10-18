import XCTest
import QuotaDesign

final class IslandProviderSelectionTests: XCTestCase {
    func testUnsetAllEmptyNoneAndSavedSelectionSurvivesNewProviders() {
        var selection = IslandProviderSelection(stored: nil)
        XCTAssertTrue(selection.includes("new-provider"))
        selection.set("codex", visible: false, available: ["codex", "claude"])
        XCTAssertFalse(selection.includes("codex")); XCTAssertTrue(selection.includes("claude"))
        XCTAssertFalse(selection.includes("new-provider"))
        let restored = IslandProviderSelection(stored: selection.selected.map(Array.init))
        XCTAssertEqual(selection, restored)
        selection.set("claude", visible: false, available: ["codex", "claude"])
        XCTAssertEqual(selection.selected, [])
        XCTAssertFalse(selection.includes("codex"))
    }
}
