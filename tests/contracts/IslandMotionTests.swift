import Foundation
import XCTest
import QuotaCore
import QuotaDesign

final class IslandMotionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func values() throws -> [QuotaPresentation] {
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/08-multiple-windows.json"))
        let snapshot = try SnapshotCodec.decode(data)
        let now = try XCTUnwrap(QuotaRules.date(snapshot.capturedAt))
        return snapshot.windows.map { QuotaPresentation(window: $0, now: now) }
    }

    func testHoverAndClickBothCloseOnExit() {
        let hovered = IslandStateReducer.reduce(IslandInteractionState(), .hoverEntered)
        XCTAssertEqual(hovered.presentation, .overview)
        XCTAssertFalse(hovered.isPinned)
        XCTAssertEqual(IslandStateReducer.reduce(hovered, .hoverExited).presentation, .collapsed)

        let pinned = IslandStateReducer.reduce(IslandInteractionState(), .islandSelected)
        XCTAssertEqual(pinned.presentation, .overview)
        XCTAssertFalse(pinned.isPinned)
        XCTAssertEqual(IslandStateReducer.reduce(pinned, .hoverExited), IslandInteractionState())
        XCTAssertEqual(IslandStateReducer.reduce(pinned, .collapse), IslandInteractionState())
    }

    func testDetailClosesOnExitAndBackReturnsToOverview() {
        let detail = IslandStateReducer.reduce(IslandInteractionState(presentation: .overview), .windowSelected("codex-primary"))
        XCTAssertEqual(detail.presentation, .detail(windowID: "codex-primary"))
        XCTAssertFalse(detail.isPinned)
        XCTAssertEqual(IslandStateReducer.reduce(detail, .hoverExited), IslandInteractionState())
        XCTAssertEqual(IslandStateReducer.reduce(detail, .back), IslandInteractionState(presentation: .overview))
    }

    func testTransitionGeometryRetargetsFromCurrentTopAnchoredFrame() {
        let collapsed = CGRect(x: 754, y: 1127, width: 292, height: 42)
        let expanded = CGRect(x: 640, y: 903, width: 520, height: 266)
        let current = IslandGeometryTransition.interpolate(from: collapsed, to: expanded, progress: 0.35)
        XCTAssertEqual(current.maxY, collapsed.maxY, accuracy: 0.0001)

        let reversedStart = IslandGeometryTransition.interpolate(from: current, to: collapsed, progress: 0)
        let reversedEnd = IslandGeometryTransition.interpolate(from: current, to: collapsed, progress: 1)
        XCTAssertEqual(reversedStart, current)
        XCTAssertEqual(reversedEnd, collapsed)
        XCTAssertEqual(reversedStart.maxY, reversedEnd.maxY, accuracy: 0.0001)
        XCTAssertEqual(IslandGeometryTransition.easeInOut(0), 0)
        XCTAssertEqual(IslandGeometryTransition.easeInOut(0.5), 0.5)
        XCTAssertEqual(IslandGeometryTransition.easeInOut(1), 1)
        XCTAssertLessThan(IslandGeometryTransition.easeInOut(0.25), 0.25)
        XCTAssertGreaterThan(IslandGeometryTransition.easeInOut(0.75), 0.75)
        XCTAssertEqual(IslandMotionTiming.openDuration, 0.22)
        XCTAssertEqual(IslandMotionTiming.closeDuration, 0.16)
    }

    func testOneTwoThreeSlotGeometryKeepsTextSizedLayout() {
        let camera = CGSize(width: 220, height: 38)
        let one = IslandLayoutMetrics.metrics(for: .collapsed, cameraSize: camera, availableWidth: 1200, visibleSlotCount: 1)
        let two = IslandLayoutMetrics.metrics(for: .collapsed, cameraSize: camera, availableWidth: 1200, visibleSlotCount: 2)
        let three = IslandLayoutMetrics.metrics(for: .collapsed, cameraSize: camera, availableWidth: 1200, visibleSlotCount: 3)
        XCTAssertEqual(one.size, two.size)
        XCTAssertEqual(two.size.height, 42)
        XCTAssertEqual(three.size.height, 66)
        XCTAssertEqual(three.size.width, two.size.width)
    }

    func testOverviewSelectionDeterminesOpeningGeometryBeforeTransition() throws {
        let groups = QuotaAccountGroup.grouped(try values())
        let first = try XCTUnwrap(groups.first)
        let second = try XCTUnwrap(groups.dropFirst().first)
        let selection = IslandOverviewSelection.resolve(groups, selectedID: second.id)
        XCTAssertEqual(selection.groupID, second.id)
        XCTAssertEqual(selection.rows, min(4, max(1, second.values.count)))
        XCTAssertNotEqual(selection.rows, IslandOverviewSelection.resolve(groups, selectedID: first.id).rows)

        let metrics = IslandLayoutMetrics.metrics(
            for: .overview,
            cameraSize: CGSize(width: 220, height: 38),
            availableWidth: 1200,
            overviewRows: selection.rows
        )
        XCTAssertEqual(metrics.size.height, CGFloat(96 + 44 * selection.rows + 38))
        XCTAssertEqual(IslandOverviewSelection.resolve(groups, selectedID: "missing").groupID, groups.first?.id)
        XCTAssertEqual(IslandLayoutMetrics.normalizeOverviewRows(0), 1)
        XCTAssertEqual(IslandLayoutMetrics.normalizeOverviewRows(8), 4)
    }

    func testCardAndCapsuleLayoutsReserveSpaceForTheirContent() {
        let contourOne = IslandLayoutMetrics.metrics(for: .overview, cameraSize: nil, availableWidth: 1200,
            overviewRows: 1, displayStyle: .contour)
        let contourTwo = IslandLayoutMetrics.metrics(for: .overview, cameraSize: nil, availableWidth: 1200,
            overviewRows: 2, displayStyle: .contour)
        let contourFour = IslandLayoutMetrics.metrics(for: .overview, cameraSize: nil, availableWidth: 1200,
            overviewRows: 4, displayStyle: .contour)
        XCTAssertEqual(contourOne, contourTwo) // Two cards share one grid row.
        XCTAssertGreaterThan(contourFour.size.height, contourTwo.size.height)
        let soft = IslandLayoutMetrics.metrics(for: .overview, cameraSize: nil, availableWidth: 1200,
            overviewRows: 1, displayStyle: .soft)
        let calibrated = IslandLayoutMetrics.metrics(for: .overview, cameraSize: nil, availableWidth: 1200,
            overviewRows: 1)
        XCTAssertGreaterThan(soft.size.height, calibrated.size.height)
    }

    func testSummarySubtitleHonorsPeriodAndResetChoices() {
        XCTAssertEqual(
            IslandSummaryText.subtitle(period: "5 小时", reset: "2 小时后重置", showPeriod: true, showReset: true),
            "5 小时 · 2 小时后重置"
        )
        XCTAssertEqual(
            IslandSummaryText.subtitle(period: "5 小时", reset: "2 小时后重置", showPeriod: false, showReset: true),
            "2 小时后重置"
        )
        XCTAssertNil(IslandSummaryText.subtitle(period: "5 小时", reset: nil, showPeriod: false, showReset: true))
        XCTAssertTrue(IslandSummaryText.accessibilityLabel(title: "5 小时", number: "42%", status: "余量偏低").contains("余量偏低"))
    }

    func testExplicitMissingSlotDoesNotSilentlyChangeIdentity() throws {
        let values = try values()
        let selected = IslandSummarySelection.select(
            values,
            leftID: "removed-window",
            rightID: values[1].window.id,
            thirdID: "",
            count: 3
        )
        XCTAssertEqual(selected.items.count, 3)
        XCTAssertTrue(selected.items[0].isMissingExplicitSelection)
        XCTAssertNil(selected.items[0].resolvedID)
        XCTAssertEqual(selected.items[1].resolvedID, values[1].window.id)
        XCTAssertEqual(selected.items[2].resolvedID, values[2].window.id)
        XCTAssertEqual(Set(selected.items.compactMap(\.resolvedID)).count, 2)
    }

    func testVisibleSlotCountClampsAndAutomaticSlotsNeverDuplicate() throws {
        let values = try values()
        XCTAssertEqual(IslandPreferenceKeys.leftWindowID, "islandLeftWindowID")
        XCTAssertEqual(IslandPreferenceKeys.rightWindowID, "islandRightWindowID")
        XCTAssertEqual(IslandPreferenceKeys.thirdWindowID, "islandThirdWindowID")
        XCTAssertEqual(IslandPreferenceKeys.visibleSlotCount, "islandVisibleSlotCount")
        XCTAssertEqual(IslandSummarySelection.normalizeVisibleCount(0), 1)
        XCTAssertEqual(IslandSummarySelection.normalizeVisibleCount(4), 3)
        let selected = IslandSummarySelection.select(values, leftID: "", rightID: "", thirdID: "", count: 99)
        XCTAssertEqual(selected.items.count, 3)
        XCTAssertEqual(Set(selected.items.compactMap(\.resolvedID)).count, 3)
    }

    func testInactiveSavedSlotIDsDoNotBlockVisibleAutomaticSlots() throws {
        let values = try values()
        let one = IslandSummarySelection.select(
            values,
            leftID: "",
            rightID: values[0].window.id,
            thirdID: values[2].window.id,
            count: 1
        )
        XCTAssertEqual(one.items.compactMap(\.resolvedID), [values[0].window.id])

        let two = IslandSummarySelection.select(
            values,
            leftID: "",
            rightID: values[1].window.id,
            thirdID: values[2].window.id,
            count: 2
        )
        XCTAssertEqual(two.items[0].value?.window.providerId, "claude")
        XCTAssertEqual(two.items[1].resolvedID, values[1].window.id)
    }
}
