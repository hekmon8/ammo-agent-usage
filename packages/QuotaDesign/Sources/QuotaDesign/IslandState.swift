import Foundation
import QuotaCore

public enum IslandPreferenceKeys {
    public static let leftWindowID = "islandLeftWindowID"
    public static let rightWindowID = "islandRightWindowID"
    public static let thirdWindowID = "islandThirdWindowID"
    public static let visibleSlotCount = "islandVisibleSlotCount"
}

public enum IslandPresentationState: Sendable, Equatable {
    case collapsed
    case overview
    case detail(windowID: String)
}

public enum IslandInteraction: Sendable, Equatable {
    case hoverEntered
    case hoverExited
    case islandSelected
    case windowSelected(String)
    case back
    case collapse
}

public struct IslandInteractionState: Sendable, Equatable {
    public var presentation: IslandPresentationState
    public var isPinned: Bool

    public init(presentation: IslandPresentationState = .collapsed, isPinned: Bool = false) {
        self.presentation = presentation
        self.isPinned = isPinned
    }
}

public enum IslandStateReducer {
    public static func reduce(_ state: IslandInteractionState, _ interaction: IslandInteraction) -> IslandInteractionState {
        var next = state
        switch interaction {
        case .hoverEntered:
            if state.presentation == .collapsed { next.presentation = .overview }
        case .hoverExited:
            next.presentation = .collapsed
            next.isPinned = false
        case .islandSelected:
            if state.presentation == .collapsed { next.presentation = .overview }
            next.isPinned = false
        case .windowSelected(let id):
            guard !id.isEmpty else { return state }
            next.presentation = .detail(windowID: id)
            next.isPinned = false
        case .back:
            if case .detail = state.presentation { next.presentation = .overview }
        case .collapse:
            next.presentation = .collapsed
            next.isPinned = false
        }
        return next
    }

    public static func reduce(_ state: IslandPresentationState, _ interaction: IslandInteraction) -> IslandPresentationState {
        reduce(IslandInteractionState(presentation: state), interaction).presentation
    }
}

public enum IslandMotionTiming {
    public static let hoverOpenDelay: Duration = .milliseconds(200)
    public static let hoverCloseDelay: Duration = .milliseconds(400)
    public static let openDuration: TimeInterval = 0.22
    public static let closeDuration: TimeInterval = 0.16

    public static func duration(from: IslandPresentationState, to: IslandPresentationState) -> TimeInterval {
        if to == .collapsed { return closeDuration }
        return openDuration
    }
}

public enum IslandGeometryTransition {
    public static func easeInOut(_ rawProgress: CGFloat) -> CGFloat {
        let progress = min(1, max(0, rawProgress))
        return progress * progress * (3 - 2 * progress)
    }

    public static func interpolate(from start: CGRect, to target: CGRect, progress rawProgress: CGFloat) -> CGRect {
        let progress = min(1, max(0, rawProgress))
        func value(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return CGRect(
            x: value(start.origin.x, target.origin.x),
            y: value(start.origin.y, target.origin.y),
            width: value(start.width, target.width),
            height: value(start.height, target.height)
        )
    }
}

public struct IslandLayoutMetrics: Sendable, Equatable {
    public let size: CGSize

    public init(size: CGSize) { self.size = size }

    public static func normalizeOverviewRows(_ count: Int) -> Int {
        min(4, max(1, count))
    }

    public static func metrics(
        for state: IslandPresentationState,
        cameraSize: CGSize?,
        availableWidth: CGFloat,
        overviewRows: Int = 4,
        visibleSlotCount: Int = 2,
        displayStyle: QuotaDisplayStyle = .calibrated
    ) -> IslandLayoutMetrics {
        let maxWidth = max(240, availableWidth - 32)
        switch state {
        case .collapsed:
            let width = cameraSize.map { max(292, $0.width + 224) } ?? 292
            let count = IslandSummarySelection.normalizeVisibleCount(visibleSlotCount)
            let height = count == 3 ? max(66, (cameraSize?.height ?? 0) + 28) : cameraSize.map { max(42, $0.height + 4) } ?? 46
            return IslandLayoutMetrics(size: CGSize(width: min(width, maxWidth), height: height))
        case .overview:
            let rows = normalizeOverviewRows(overviewRows)
            let contentHeight: Int
            switch displayStyle {
            case .contour: contentHeight = min(184, ((rows + 1) / 2) * 92)
            case .calibrated: contentHeight = 44 * rows
            case .soft, .ring: contentHeight = min(184, 52 * rows)
            }
            let height = CGFloat(96 + contentHeight) + (cameraSize?.height ?? 0)
            return IslandLayoutMetrics(size: CGSize(width: min(520, maxWidth), height: height))
        case .detail:
            let height = 280 + (cameraSize?.height ?? 0)
            return IslandLayoutMetrics(size: CGSize(width: min(520, maxWidth), height: height))
        }
    }
}

public enum IslandOverviewSelection {
    public struct Result: Sendable, Equatable {
        public let groupID: String?
        public let rows: Int

        public init(groupID: String?, rows: Int) {
            self.groupID = groupID
            self.rows = rows
        }
    }

    public static func resolve(_ groups: [QuotaAccountGroup], selectedID: String?) -> Result {
        let selected = selectedID.flatMap { id in groups.first { $0.id == id } } ?? groups.first
        return Result(
            groupID: selected?.id,
            rows: IslandLayoutMetrics.normalizeOverviewRows(selected?.values.count ?? 0)
        )
    }
}

public enum IslandSummaryText {
    public static func subtitle(
        period: String,
        reset: String?,
        showPeriod: Bool,
        showReset: Bool
    ) -> String? {
        let text = [showPeriod ? period : nil, showReset ? reset : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    public static func accessibilityLabel(title: String, number: String, status: String) -> String {
        "\(title), \(number), \(status)"
    }
}

/// Explicit selections keep their slot identity even while a provider is unavailable.
public enum IslandSummarySelection {
    public struct Slot: Sendable {
        public let explicitID: String?
        public let value: QuotaPresentation?

        public var resolvedID: String? { value?.window.id }
        public var isMissingExplicitSelection: Bool { explicitID != nil && value == nil }
    }

    public struct Slots: Sendable {
        public let items: [Slot]

        public var left: QuotaPresentation? { items.indices.contains(0) ? items[0].value : nil }
        public var right: QuotaPresentation? { items.indices.contains(1) ? items[1].value : nil }
        public var third: QuotaPresentation? { items.indices.contains(2) ? items[2].value : nil }
    }

    public static func select(_ values: [QuotaPresentation], leftID: String, rightID: String) -> Slots {
        select(values, leftID: leftID, rightID: rightID, thirdID: "", count: 2)
    }

    public static func select(
        _ values: [QuotaPresentation],
        leftID: String,
        rightID: String,
        thirdID: String,
        count: Int
    ) -> Slots {
        let requested = [leftID, rightID, thirdID]
        let activeRequested = Array(requested.prefix(normalizeVisibleCount(count)))
        let reservedIDs = Set(activeRequested.filter { !$0.isEmpty })
        var usedIDs = Set<String>()
        var usedProviders = Set(activeRequested.compactMap { requestedID in
            values.first { $0.window.id == requestedID }?.window.providerId
        })
        let slots = activeRequested.map { requestedID -> Slot in
            let explicitID = requestedID.isEmpty ? nil : requestedID
            let value: QuotaPresentation?
            if let explicitID {
                value = values.first { $0.window.id == explicitID && !usedIDs.contains($0.window.id) }
            } else {
                value = values.first {
                    !usedIDs.contains($0.window.id) && !reservedIDs.contains($0.window.id)
                        && !usedProviders.contains($0.window.providerId)
                } ?? values.first { !usedIDs.contains($0.window.id) && !reservedIDs.contains($0.window.id) }
            }
            if let value {
                usedIDs.insert(value.window.id)
                usedProviders.insert(value.window.providerId)
            }
            return Slot(explicitID: explicitID, value: value)
        }
        return Slots(items: slots)
    }

    public static func normalizeVisibleCount(_ count: Int) -> Int {
        min(3, max(1, count))
    }
}

/// Local presentation preferences; provider status and remaining quota stay visible.
/// Compact and minimal presentations always retain a readable quota value.
public enum ActivityCompactStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case ring, number, capsule
    public var id: String { rawValue }
    public var title: String {
        switch self { case .ring: L("design.compact.ring"); case .number: L("design.compact.number"); case .capsule: L("design.compact.capsule") }
    }
    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? .ring }
    public init(from decoder: any Decoder) throws {
        self.init(storedValue: try decoder.singleValueContainer().decode(String.self))
    }
}

public struct ActivityDisplayOptions: Codable, Hashable, Sendable {
    public var showWindowName: Bool
    public var showProgress: Bool
    public var showObservationTime: Bool
    public var displayStyle: QuotaDisplayStyle
    public var compactStyle: ActivityCompactStyle

    public init(showWindowName: Bool = true, showProgress: Bool = true, showObservationTime: Bool = true,
                displayStyle: QuotaDisplayStyle = .calibrated, compactStyle: ActivityCompactStyle = .ring) {
        self.showWindowName = showWindowName
        self.showProgress = showProgress
        self.showObservationTime = showObservationTime
        self.displayStyle = displayStyle
        self.compactStyle = compactStyle
    }

    private enum CodingKeys: String, CodingKey {
        case showWindowName, showProgress, showObservationTime, displayStyle, compactStyle
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showWindowName = try values.decodeIfPresent(Bool.self, forKey: .showWindowName) ?? true
        showProgress = try values.decodeIfPresent(Bool.self, forKey: .showProgress) ?? true
        showObservationTime = try values.decodeIfPresent(Bool.self, forKey: .showObservationTime) ?? true
        displayStyle = try values.decodeIfPresent(QuotaDisplayStyle.self, forKey: .displayStyle) ?? .calibrated
        compactStyle = try values.decodeIfPresent(ActivityCompactStyle.self, forKey: .compactStyle) ?? .ring
    }
}
