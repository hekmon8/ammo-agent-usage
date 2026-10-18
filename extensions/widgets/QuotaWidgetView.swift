import Foundation
import SwiftUI
import QuotaCore
import QuotaDesign

/// Per-instance selections take precedence over the app defaults.
public enum WidgetSelectionPolicy {
    public static let maximumWindowCount = 2
    public static func resolve(configured: [String], defaults: [String]) -> [String] {
        var seen = Set<String>()
        return Array((configured.isEmpty ? defaults : configured).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(maximumWindowCount))
    }
}

/// Entry dates preserve the observation's original freshness across timeline entries.
public struct WidgetProjection: Sendable {
    public let values: [QuotaPresentation]
    public let entryDate: Date
    public let isLocked: Bool
    public let requiresWindowSelection: Bool
    public let isFixedWindowUnknown: Bool
    public let missingWindowSelectionCount: Int

    public init(
        snapshot: Snapshot?,
        entryDate: Date,
        isLocked: Bool = false,
        offline: Bool = false,
        fixedWindowID: String? = nil,
        fixedWindowIDs: [String] = [],
        requiresWindowSelection: Bool = false
    ) {
        self.entryDate = entryDate
        self.isLocked = isLocked
        let requestedIDs = WidgetSelectionPolicy.resolve(configured: fixedWindowIDs, defaults: fixedWindowID.map { [$0] } ?? [])
        self.requiresWindowSelection = requiresWindowSelection && requestedIDs.isEmpty
        let selected = requestedIDs.compactMap { id in snapshot?.windows.first(where: { $0.id == id }) }
        missingWindowSelectionCount = requestedIDs.count - selected.count
        isFixedWindowUnknown = !requestedIDs.isEmpty && selected.isEmpty
        let windows: [QuotaWindow]
        if self.requiresWindowSelection {
            windows = []
        } else if !requestedIDs.isEmpty {
            // Every configured widget instance stays bound to its explicit IDs.
            // A missing choice is reported and never replaced by another source.
            windows = selected
        } else {
            windows = Array(snapshot?.windows.prefix(2) ?? [])
        }
        values = windows.map {
            QuotaPresentation(window: $0, now: entryDate, offline: offline, locked: isLocked)
        }
    }

    public var stateText: String {
        if isLocked { return L("widget.locked") }
        if requiresWindowSelection { return L("widget.state.select.window") }
        if isFixedWindowUnknown { return L("widget.state.window.unknown") }
        let status = values.isEmpty ? L("widget.connect.mac") : values.map(\.status).joined(separator: L("widget.state.separator"))
        return missingWindowSelectionCount > 0 ? status + L("widget.state.window.lost") : status
    }
}

/// WidgetKit may defer reloads. This planner bounds requested network/cache work to
/// 30 minutes and creates local entries when an already-known freshness or reset
/// boundary occurs. It never predicts a new quota value at either boundary.
public enum WidgetTimelinePlanner {
    public static func nextRefreshDate(for projection: WidgetProjection) -> Date {
        projection.entryDate.addingTimeInterval(30 * 60)
    }

    public static func entryDates(for projection: WidgetProjection) -> [Date] {
        let refreshDate = nextRefreshDate(for: projection)
        let boundaries = projection.values.flatMap { value -> [Date] in
            let candidates = [value.window.staleAt, value.window.window.resetsAt]
                .compactMap { $0 }
                .compactMap(QuotaRules.date)
            return candidates.filter { $0 > projection.entryDate }
        }
        return Array(Set(boundaries.filter { $0 <= refreshDate } + [refreshDate])).sorted()
    }
}

public struct QuotaWidgetView: View {
    let projection: WidgetProjection
    let family: WidgetFamilyKind

    public init(values: [QuotaPresentation], entryDate: Date = .now, family: WidgetFamilyKind = .systemSmall) {
        self.projection = WidgetProjection(values: values, entryDate: entryDate)
        self.family = family
    }

    public init(projection: WidgetProjection, family: WidgetFamilyKind = .systemSmall) {
        self.projection = projection
        self.family = family
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: family.isAccessory ? 2 : 8) {
            if projection.isLocked {
                Label(L("widget.locked"), systemImage: "lock.fill")
            } else if projection.requiresWindowSelection {
                Label(L("widget.view.select.window"), systemImage: "slider.horizontal.3")
            } else if projection.isFixedWindowUnknown {
                Label(L("widget.view.window.unknown"), systemImage: "questionmark.circle")
                Text(L("widget.view.window.notfound")).font(.caption)
            } else if projection.values.isEmpty {
                Label(L("widget.connect.mac"), systemImage: "desktopcomputer")
                Text(L("widget.view.stale")).font(.caption)
            } else {
                if family == .accessoryCircular {
                    VStack(spacing: 2) {
                        Image(systemName: ProviderCatalog.identity(for: displayed[0].window.providerId).systemSymbol)
                            .font(.caption2)
                        Text(displayed[0].number)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                } else if family == .systemMedium && displayed.count == 2 {
                    HStack(spacing: 16) {
                        WidgetTile(value: displayed[0], style: displayStyle)
                        Divider()
                        WidgetTile(value: displayed[1], style: displayStyle)
                    }
                } else {
                    ForEach(displayed.indices, id: \.self) { index in
                        if index > 0 && !family.isAccessory { Divider() }
                        WidgetWindow(value: displayed[index], compact: family.isAccessory, dense: family == .systemSmall && displayed.count > 1, style: displayStyle)
                    }
                }
                if projection.missingWindowSelectionCount > 0 {
                    Label(L("widget.view.window.lost"), systemImage: "questionmark.circle").font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(projection.stateText)
    }

    private var displayed: [QuotaPresentation] {
        Array(projection.values.prefix(family.maximumWindowCount))
    }

    private var displayStyle: QuotaDisplayStyle { WidgetAppearance.displayStyle }
}

private enum WidgetAppearance {
    static var displayStyle: QuotaDisplayStyle {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "QuotaAppGroup") as? String,
              group.hasPrefix("group."),
              let stored = UserDefaults(suiteName: group)?.string(forKey: QuotaAppearanceKeys.displayStyle)
        else { return .calibrated }
        return QuotaDisplayStyle(storedValue: stored)
    }
}

private struct WidgetWindow: View {
    let value: QuotaPresentation
    let compact: Bool
    var dense = false
    let style: QuotaDisplayStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Image(systemName: ProviderCatalog.identity(for: value.window.providerId).systemSymbol)
                    .font(.caption2)
                Text(value.window.shortDisplayName)
                    .font(.caption2).lineLimit(1)
                Spacer(minLength: 2)
                Text(value.number)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .monospacedDigit()
                    .foregroundStyle(QuotaVisualState(value).color(for: scheme))
            }
        } else if style == .ring {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        ProviderMark(providerID: value.window.providerId, size: 18)
                        Text(ProviderCatalog.identity(for: value.window.providerId).shortName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(value.window.shortDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if value.visibleBps == nil, value.window.unit == .money {
                        Text(L("widget.view.no.limit"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                QuotaRingGauge(value: value, diameter: dense ? 36 : 46)
            }
        } else {
            // Deliberately label + number + bar only: freshness is carried by the
            // number's color, and the full status stays in the accessibility label.
            VStack(alignment: .leading, spacing: dense ? 4 : 7) {
                HStack(spacing: 7) {
                    if !dense { ProviderMark(providerID: value.window.providerId, size: 24) }
                    if dense {
                        Text(ProviderCatalog.identity(for: value.window.providerId).shortName + " · " + value.window.shortDisplayName)
                            .font(.caption2.weight(.semibold)).lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ProviderCatalog.identity(for: value.window.providerId).shortName)
                                .font(.caption.weight(.semibold)).lineLimit(1)
                            Text(value.window.shortDisplayName)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if !dense {
                        Text(value.number)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .minimumScaleFactor(0.7).lineLimit(1)
                            .monospacedDigit()
                            .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                            .contentTransition(.numericText())
                    }
                }
                if dense {
                    Text(value.number)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                        .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                }
                if value.visibleBps != nil {
                    QuotaStyledProgress(value: value, style: style, height: dense ? 3 : nil)
                } else if value.window.unit == .money {
                    Text(L("widget.view.no.limit"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct WidgetTile: View {
    let value: QuotaPresentation
    let style: QuotaDisplayStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderMark(providerID: value.window.providerId, size: 20)
                Text(ProviderCatalog.identity(for: value.window.providerId).shortName)
                    .font(.caption.weight(.semibold)).lineLimit(1)
            }
            if style == .ring {
                HStack(spacing: 8) {
                    QuotaRingGauge(value: value, diameter: 52)
                    Spacer(minLength: 0)
                }
                Text(value.window.shortDisplayName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(value.number).font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                Text(value.window.shortDisplayName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if value.visibleBps != nil { QuotaStyledProgress(value: value, style: style, height: 4) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public enum WidgetFamilyKind: Sendable, Hashable {
    case systemSmall, systemMedium, accessoryCircular, accessoryRectangular
    public var maximumWindowCount: Int { self == .accessoryCircular ? 1 : WidgetSelectionPolicy.maximumWindowCount }
    fileprivate var isAccessory: Bool { self == .accessoryCircular || self == .accessoryRectangular }
}

/// The Activity renderer uses this pure projection so elapsed, reset and stale
/// timestamps outrank a payload's earlier low/exhausted display-state label.
public enum ActivityQuotaVisualState: Sendable, Equatable {
    case normal, low, exhausted, historical, unavailable, ended

    private var quotaVisualState: QuotaVisualState {
        switch self {
        case .normal: .normal
        case .low: .low
        case .exhausted: .exhausted
        case .historical, .ended: .historical
        case .unavailable: .unavailable
        }
    }

    func color(for scheme: ColorScheme) -> Color {
        quotaVisualState.color(for: scheme)
    }
}

public struct ActivityDisplaySemantics: Sendable, Equatable {
    public let number: String
    public let status: String
    public let symbol: String
    public let visualState: ActivityQuotaVisualState
    public let remainingBps: Int?

    public init(remainingBps: Int?, displayState: String, observedAt: Int64?, staleAt: Int64?, resetsAt: Int64?, endsAt: Int64, now: Int64, systemIsStale: Bool = false) {
        if now >= endsAt || displayState == "systemEnded" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.systemEnded"); symbol = "stopwatch.fill"; visualState = .ended; self.remainingBps = nil
        } else if displayState == "ended" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.ended"); symbol = "stop.fill"; visualState = .ended; self.remainingBps = nil
        } else if displayState == "locked" {
            number = "—"; status = L("widget.locked"); symbol = "lock.fill"; visualState = .unavailable; self.remainingBps = nil
        } else if displayState == "authRequired" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.auth.required"); symbol = "key.fill"; visualState = .historical; self.remainingBps = nil
        } else if displayState == "unavailable" {
            number = "—"; status = L("widget.activity.quota.unknown"); symbol = "questionmark.circle"; visualState = .unavailable; self.remainingBps = nil
        } else if displayState == "resetPending" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.reset.pending"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else if displayState == "stale" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.stale"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else if displayState == "offline" {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.offline"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else if displayState == "clockSkew" || observedAt.map({ $0 > now + 120 }) == true {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.clock.skew"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else if let reset = resetsAt, reset <= now, observedAt.map({ $0 < reset }) ?? true {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.reset.pending"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else if observedAt == nil || systemIsStale || (staleAt.map({ $0 <= now }) ?? true) {
            number = Self.number(remainingBps, displayState: displayState); status = L("widget.activity.stale"); symbol = "clock"; visualState = .historical; self.remainingBps = nil
        } else {
            number = Self.number(remainingBps, displayState: displayState)
            self.remainingBps = displayState == "unlimited" ? nil : remainingBps
            switch displayState {
            case "low":
                status = L("widget.activity.low"); symbol = "exclamationmark.circle"; visualState = .low
            case "exhausted":
                status = L("widget.activity.exhausted"); symbol = "exclamationmark.circle"; visualState = .exhausted
            default:
                status = observedAt.map { L("widget.activity.observed.at", Date(timeIntervalSince1970: Double($0)).formatted(date: .omitted, time: .shortened)) } ?? L("widget.activity.observed.unknown")
                symbol = "gauge.with.dots.needle.33percent"; visualState = .normal
            }
        }
    }

    private static func number(_ remainingBps: Int?, displayState: String) -> String {
        if displayState == "unlimited" { return L("widget.number.unlimited") }
        guard let remainingBps else { return "—" }
        return String(format: "%.2f", Double(remainingBps) / 100)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + "%"
    }
}

#if os(iOS) && canImport(QuotaSync)
import CryptoKit
import QuotaSync

/// Reads only a `VerifiedCache` supplied by the paired app configuration. Failure
/// leaves the existing ciphertext untouched and projects a locked/unavailable state
/// rather than accepting a plaintext or unverified snapshot.
public actor VerifiedWidgetSnapshotSource: WidgetSnapshotReading {
    private let cache: VerifiedCache
    private let keyProvider: @Sendable () throws -> Data

    public init(cache: VerifiedCache, keyProvider: @escaping @Sendable () throws -> Data) {
        self.cache = cache; self.keyProvider = keyProvider
    }

    public func loadWidgetSnapshot() async -> WidgetSnapshotLoad {
        do {
            let keyData = try keyProvider()
            guard keyData.count == 32 else { return WidgetSnapshotLoad(snapshot: nil, isLocked: true) }
            return WidgetSnapshotLoad(snapshot: try await cache.latest(key: SymmetricKey(data: keyData)))
        } catch {
            return WidgetSnapshotLoad(snapshot: nil, isLocked: true)
        }
    }
}
#endif

private extension WidgetProjection {
    init(values: [QuotaPresentation], entryDate: Date) {
        self.values = Array(values.prefix(2)); self.entryDate = entryDate; isLocked = false; requiresWindowSelection = false; isFixedWindowUnknown = false; missingWindowSelectionCount = 0
    }
}

public struct WidgetWindowDescriptor: Codable, Sendable, Hashable, Identifiable {
    public static let preferencesKey = "quota-island.widget-window-catalog.v1"
    public let id: String
    public let providerID: String
    public let providerName: String
    public let accountAlias: String
    public let windowName: String
    /// Optional so the original five-field catalog remains decodable.
    public let quotaKey: String?
    public let unit: QuotaWindow.Unit?
    public let windowDurationSeconds: Int?
    public let accountOrdinal: Int?

    public init(id: String, providerID: String, providerName: String, accountAlias: String, windowName: String,
                quotaKey: String? = nil, unit: QuotaWindow.Unit? = nil,
                windowDurationSeconds: Int? = nil, accountOrdinal: Int? = nil) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.accountAlias = accountAlias
        self.windowName = windowName
        self.quotaKey = quotaKey
        self.unit = unit
        self.windowDurationSeconds = windowDurationSeconds
        self.accountOrdinal = accountOrdinal
    }

    /// Catalog fields are display-only; the original window ID remains the choice.
    /// Never copy a private account alias or ID into the plaintext catalog.
    public init(window: QuotaWindow, accountOrdinal: Int) {
        self.init(id: window.id, providerID: window.providerId,
                  providerName: ProviderCatalog.identity(for: window.providerId).displayName,
                  accountAlias: L("widget.account.generic", accountOrdinal),
                  windowName: window.shortDisplayName, quotaKey: window.quotaKey, unit: window.unit,
                  windowDurationSeconds: window.window.durationSeconds, accountOrdinal: accountOrdinal)
    }

    public var localizedWindowName: String {
        if let quotaKey, let unit {
            if windowDurationSeconds == nil, let position = Self.positionLabel(for: quotaKey) {
                return position
            }
            return QuotaWindow.shortDisplayName(providerID: providerID, quotaKey: quotaKey, unit: unit,
                                               windowDurationSeconds: windowDurationSeconds)
        }
        // Old catalogs stored raw primary/secondary keys. Keep those readable
        // without guessing five hours or a week; preserve arbitrary friendly text.
        if let position = Self.positionLabel(for: windowName) { return position }
        switch windowName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "balance": return L(providerID == "amp" ? "quota.label.topUpBalance" : "quota.label.availableBalance")
        case "free-balance": return L("quota.label.freeToday")
        case "credit-balance": return L(providerID == "codex" || providerID == "codex-cli" ? "quota.label.creditBalance" : "quota.label.availableCredits")
        case "rate-limit-reset-credits": return L("quota.label.remainingResets")
        case "rate-limit-reset-credits-week": return L("quota.label.remainingWeekResets")
        case "cost-spend", "spend", "monthly-spend":
            return QuotaWindow.shortDisplayName(providerID: providerID, quotaKey: windowName, unit: .money, windowDurationSeconds: nil)
        default: return windowName
        }
    }

    private static func positionLabel(for key: String) -> String? {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "primary", "codex-primary", "default-primary": return L("widget.intent.primaryWindow")
        case "secondary", "codex-secondary", "default-secondary": return L("widget.intent.secondaryWindow")
        case "codex-spark", "codex_bengalfox-primary", "codex-spark-primary", "spark-primary":
            return "Spark · " + L("widget.intent.primaryWindow")
        case "codex-spark-weekly", "codex_bengalfox-secondary", "codex-spark-secondary", "spark-secondary":
            return "Spark · " + L("widget.intent.secondaryWindow")
        default: return nil
        }
    }

    public var localizedAccountAlias: String {
        guard let accountOrdinal, accountOrdinal > 0 else { return accountAlias }
        return L("widget.account.generic", accountOrdinal)
    }
}

/// Resolves persisted AppIntent identifiers without allowing a removed choice to
/// become indistinguishable from an unconfigured widget. The tombstone retains
/// the original ID so timeline projection can report the missing fixed window.
public enum WidgetWindowEntityResolver {
    public static func descriptors(
        for identifiers: [String],
        in catalog: [WidgetWindowDescriptor]
    ) -> [WidgetWindowDescriptor] {
        identifiers.compactMap { id in
            guard !id.isEmpty else { return nil }
            return catalog.first(where: { $0.id == id }) ?? WidgetWindowDescriptor(
                id: id,
                providerID: "",
                providerName: L("widget.tombstone.provider"),
                accountAlias: L("widget.tombstone.account"),
                windowName: L("widget.tombstone.window")
            )
        }
    }
}

#if os(iOS)
import WidgetKit
import AppIntents
// iOS 17's ActivityKit update/end declarations are imported as non-Sendable even
// though this coordinator serializes each activity on the main actor. Keep this
// compatibility boundary limited to the Apple framework, not application types.
@preconcurrency import ActivityKit

public struct WidgetSnapshotLoad: Sendable {
    public let snapshot: Snapshot?
    public let isLocked: Bool
    public let offline: Bool
    public let fixedWindowID: String?
    public let fixedWindowIDs: [String]
    public let requiresWindowSelection: Bool

    public init(snapshot: Snapshot?, isLocked: Bool = false, offline: Bool = false, fixedWindowID: String? = nil, fixedWindowIDs: [String] = [], requiresWindowSelection: Bool = false) {
        self.snapshot = snapshot; self.isLocked = isLocked; self.offline = offline
        self.fixedWindowID = fixedWindowID
        self.fixedWindowIDs = WidgetSelectionPolicy.resolve(configured: fixedWindowIDs, defaults: fixedWindowID.map { [$0] } ?? [])
        self.requiresWindowSelection = requiresWindowSelection
    }
}

/// The extension gets one bounded load for a system-provided timeline request. A
/// concrete source must read the same verified App Group ciphertext as the phone;
/// `UnavailableWidgetSnapshotSource` exists for an unpaired or locked extension.
public protocol WidgetSnapshotReading: Sendable {
    func loadWidgetSnapshot() async -> WidgetSnapshotLoad
}

public struct UnavailableWidgetSnapshotSource: WidgetSnapshotReading {
    public init() {}
    public func loadWidgetSnapshot() async -> WidgetSnapshotLoad { WidgetSnapshotLoad(snapshot: nil) }
}

public struct QuotaWidgetTimelineEntry: TimelineEntry {
    public let date: Date
    public let projection: WidgetProjection

    public init(date: Date, projection: WidgetProjection) {
        self.date = date; self.projection = projection
    }
}

public struct QuotaWidgetTimelineProvider: TimelineProvider {
    public typealias Entry = QuotaWidgetTimelineEntry
    private let source: any WidgetSnapshotReading

    public init(source: any WidgetSnapshotReading = UnavailableWidgetSnapshotSource()) { self.source = source }

    public func placeholder(in context: Context) -> Entry {
        Entry(date: .now, projection: WidgetProjection(snapshot: nil, entryDate: .now))
    }

    public func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        let source = source
        Task {
            let loaded = await source.loadWidgetSnapshot()
            let now = Date.now
            completion(Entry(date: now, projection: WidgetProjection(snapshot: loaded.snapshot, entryDate: now, isLocked: loaded.isLocked, offline: loaded.offline, fixedWindowIDs: loaded.fixedWindowIDs, requiresWindowSelection: loaded.requiresWindowSelection)))
        }
    }

    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        let source = source
        Task {
            let loaded = await source.loadWidgetSnapshot()
            let now = Date.now
            let projection = WidgetProjection(snapshot: loaded.snapshot, entryDate: now, isLocked: loaded.isLocked, offline: loaded.offline, fixedWindowIDs: loaded.fixedWindowIDs, requiresWindowSelection: loaded.requiresWindowSelection)
            let entries = [Entry(date: now, projection: projection)] + WidgetTimelinePlanner.entryDates(for: projection).map { boundary in
                Entry(date: boundary, projection: WidgetProjection(snapshot: loaded.snapshot, entryDate: boundary, isLocked: loaded.isLocked, offline: loaded.offline, fixedWindowIDs: loaded.fixedWindowIDs, requiresWindowSelection: loaded.requiresWindowSelection))
            }
            completion(Timeline(entries: entries, policy: .after(WidgetTimelinePlanner.nextRefreshDate(for: projection))))
        }
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct QuotaWindowEntity: AppEntity, Identifiable, Hashable {
    // AppIntents metadata is extracted statically at export time, so these
    // sites must stay literal; the keys resolve from each host's own
    // Localizable.strings (native/Phone and native/Widgets), not the shared L10n table.
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "widget.intent.typeName") }
    public static let defaultQuery = QuotaWindowEntityQuery()

    public let id: String
    public let providerName: String
    public let accountAlias: String
    public let windowName: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(providerName) · \(windowName)", subtitle: "\(accountAlias)")
    }

    public init(_ descriptor: WidgetWindowDescriptor) {
        id = descriptor.id
        providerName = descriptor.providerName
        accountAlias = descriptor.localizedAccountAlias
        windowName = descriptor.localizedWindowName
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct QuotaWindowEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [QuotaWindowEntity] {
        WidgetWindowEntityResolver.descriptors(for: identifiers, in: Self.descriptors())
            .map(QuotaWindowEntity.init)
    }

    public func suggestedEntities() async throws -> [QuotaWindowEntity] {
        Self.descriptors().map(QuotaWindowEntity.init)
    }

    private static func descriptors() -> [WidgetWindowDescriptor] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "QuotaAppGroup") as? String,
              group.hasPrefix("group."),
              let preferences = UserDefaults(suiteName: group),
              let data = preferences.data(forKey: WidgetWindowDescriptor.preferencesKey),
              let descriptors = try? JSONDecoder().decode([WidgetWindowDescriptor].self, from: data)
        else { return [] }
        return descriptors
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct QuotaWidgetConfigurationIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "widget.intent.title" }
    public static var description: IntentDescription { IntentDescription("widget.intent.description") }

    @Parameter(title: "widget.intent.primaryWindow")
    public var primaryWindow: QuotaWindowEntity?

    @Parameter(title: "widget.intent.secondaryWindow")
    public var secondaryWindow: QuotaWindowEntity?

    public init() {}
}

@available(iOSApplicationExtension 17.0, *)
public struct QuotaWidgetIntentTimelineProvider: AppIntentTimelineProvider {
    public typealias Entry = QuotaWidgetTimelineEntry
    public typealias Intent = QuotaWidgetConfigurationIntent
    private let source: any WidgetSnapshotReading

    public init(source: any WidgetSnapshotReading = UnavailableWidgetSnapshotSource()) { self.source = source }

    public func placeholder(in context: Context) -> Entry {
        Entry(date: .now, projection: WidgetProjection(snapshot: nil, entryDate: .now))
    }

    public func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        let loaded = await source.loadWidgetSnapshot()
        return entry(loaded: loaded, configuration: configuration, at: .now)
    }

    public func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let loaded = await source.loadWidgetSnapshot()
        let now = Date.now
        let current = entry(loaded: loaded, configuration: configuration, at: now)
        let entries = [current] + WidgetTimelinePlanner.entryDates(for: current.projection).map {
            entry(loaded: loaded, configuration: configuration, at: $0)
        }
        return Timeline(entries: entries, policy: .after(WidgetTimelinePlanner.nextRefreshDate(for: current.projection)))
    }

    private func entry(loaded: WidgetSnapshotLoad, configuration: Intent, at date: Date) -> Entry {
        let configured = [configuration.primaryWindow?.id, configuration.secondaryWindow?.id].compactMap { $0 }
        let fallback = WidgetSelectionPolicy.resolve(configured: configured, defaults: loaded.fixedWindowIDs)
        return Entry(date: date, projection: WidgetProjection(
            snapshot: loaded.snapshot,
            entryDate: date,
            isLocked: loaded.isLocked,
            offline: loaded.offline,
            fixedWindowIDs: fallback,
            requiresWindowSelection: loaded.requiresWindowSelection && fallback.isEmpty
        ))
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct AmmoWidget: Widget {
    public let kind = "QuotaIslandWidget"
    private let provider: QuotaWidgetIntentTimelineProvider

    public init() { provider = QuotaWidgetIntentTimelineProvider() }
    public init(provider: QuotaWidgetIntentTimelineProvider) { self.provider = provider }

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuotaWidgetConfigurationIntent.self, provider: provider) { entry in
            SystemQuotaWidgetView(projection: entry.projection)
                .containerBackground(for: .widget) { WidgetPaperBackground() }
        }
        .configurationDisplayName("Ammo")
        .description(L10n.resource("widget.intent.configDescription"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// HIG requires system widgets to stay legible over any wallpaper: the container
/// background is the brand paper surface, and the system layers its Tinted and
/// Clear home-screen appearances on top when the user picks them.
private struct WidgetPaperBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PaperInk(scheme).surface
    }
}

private struct SystemQuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let projection: WidgetProjection

    var body: some View {
        if let windowID = projection.values.first?.window.id {
            QuotaWidgetView(projection: projection, family: WidgetFamilyKind(family))
                .widgetURL(activityURL(windowID: windowID))
        } else {
            QuotaWidgetView(projection: projection, family: WidgetFamilyKind(family))
        }
    }
}

private extension WidgetFamilyKind {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemMedium: self = .systemMedium
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryRectangular: self = .accessoryRectangular
        default: self = .systemSmall
        }
    }
}

/// Content is intentionally small and contains no account ID, Provider credential,
/// history, or complete Snapshot. The payload remains comfortably below the 1 KiB
/// project target when labels are kept bounded by the coordinator.
public struct QuotaActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var remainingBps: Int?
        public var displayState: String
        public var observedAt: Int64?
        public var staleAt: Int64?
        public var resetsAt: Int64?
        public var label: String
        public var sequence: Int64

        public init(remainingBps: Int?, displayState: String, observedAt: Int64?, staleAt: Int64?, resetsAt: Int64?, label: String, sequence: Int64) {
            self.remainingBps = remainingBps
            self.displayState = displayState
            self.observedAt = observedAt
            self.staleAt = staleAt
            self.resetsAt = resetsAt
            self.label = String(label.prefix(48))
            self.sequence = sequence
        }
    }
    public var sessionID: String
    public var windowID: String
    public var endsAt: Int64
    /// Optional for decoding activities created before display customization.
    public var displayOptions: ActivityDisplayOptions?

    public init(sessionID: String, windowID: String, endsAt: Int64, displayOptions: ActivityDisplayOptions? = nil) {
        self.sessionID = sessionID; self.windowID = windowID; self.endsAt = endsAt
        self.displayOptions = displayOptions
    }
}

public struct ActivityStatusPresentation: Sendable, Equatable {
    public let number: String
    public let status: String
    public let symbol: String
    public let visualState: ActivityQuotaVisualState
    public let remainingBps: Int?

    public init(
        state: QuotaActivityAttributes.ContentState,
        endsAt: Int64,
        now: Int64 = Int64(Date.now.timeIntervalSince1970),
        systemIsStale: Bool = false
    ) {
        let semantics = ActivityDisplaySemantics(
            remainingBps: state.remainingBps,
            displayState: state.displayState,
            observedAt: state.observedAt,
            staleAt: state.staleAt,
            resetsAt: state.resetsAt,
            endsAt: endsAt,
            now: now,
            systemIsStale: systemIsStale
        )
        number = semantics.number
        status = semantics.status
        symbol = semantics.symbol
        visualState = semantics.visualState
        remainingBps = semantics.remainingBps
    }
}

/// The worker integration owns authentication and transport. This protocol makes the
/// token lifecycle explicit while keeping raw APNs tokens out of UserDefaults/files.
public protocol ActivityTokenRegistering: Sendable {
    func replacePushToken(_ token: Data, sessionID: String) async
    func endActivity(sessionID: String) async
}

@MainActor
public final class QuotaActivityCoordinator {
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var dismissalTasks: [String: Task<Void, Never>] = [:]
    private let tokenRegistrar: any ActivityTokenRegistering

    /// Lifecycle updates change the host's display status, never its selection
    /// or the number of activities. Only a user action starts a new display.
    public var onActivityStateChanged: ((QuotaActivityAttributes) -> Void)?

    public static func isRunning(_ activity: Activity<QuotaActivityAttributes>, now: Date = .now) -> Bool {
        guard activity.attributes.endsAt > Int64(now.timeIntervalSince1970) else { return false }
        switch activity.activityState {
        case .active, .stale, .pending: return true
        case .ended, .dismissed: return false
        @unknown default: return false
        }
    }

    public init(tokenRegistrar: any ActivityTokenRegistering) { self.tokenRegistrar = tokenRegistrar }

    /// Called only from an explicit foreground user action. `endsAt` is not extended
    /// by update calls and there is no timer or automatic replacement activity.
    public func start(sessionID: String, windowID: String, endsAt: Date, initial: QuotaActivityAttributes.ContentState, remoteUpdates: Bool = false, displayOptions: ActivityDisplayOptions? = nil) throws {
        let remaining = endsAt.timeIntervalSinceNow
        let running = Activity<QuotaActivityAttributes>.activities.filter { Self.isRunning($0) }
        guard !sessionID.isEmpty, !windowID.isEmpty,
              remaining > 0, remaining <= 8 * 60 * 60,
              tokenTasks[sessionID] == nil,
              running.count < 2,
              !running.contains(where: { $0.attributes.windowID == windowID })
        else { return }
        let attributes = QuotaActivityAttributes(sessionID: sessionID, windowID: windowID, endsAt: Int64(endsAt.timeIntervalSince1970), displayOptions: displayOptions)
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: initial, staleDate: min(initial.staleAt.map { Date(timeIntervalSince1970: Double($0)) } ?? .now, endsAt)),
            pushType: remoteUpdates ? .token : nil
        )
        observe(activity)
    }

    public func update(sessionID: String, content: QuotaActivityAttributes.ContentState, staleAt: Date?) async {
        guard let activity = activity(sessionID: sessionID), Self.isRunning(activity) else { return }
        let deadline = Date(timeIntervalSince1970: TimeInterval(activity.attributes.endsAt))
        await activity.update(ActivityContent(state: content, staleDate: min(staleAt ?? deadline, deadline)))
    }

    public func end(sessionID: String, final: QuotaActivityAttributes.ContentState, immediately: Bool = true) async {
        tokenTasks.removeValue(forKey: sessionID)?.cancel()
        dismissalTasks.removeValue(forKey: sessionID)?.cancel()
        if let activity = activity(sessionID: sessionID) {
            var final = final
            final.displayState = "ended"
            await activity.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: immediately ? .immediate : .default
            )
        }
        await tokenRegistrar.endActivity(sessionID: sessionID)
        if let activity = activity(sessionID: sessionID) { onActivityStateChanged?(activity.attributes) }
    }

    /// Ends an existing activity from its own content when its source window is no
    /// longer present in the latest snapshot.
    public func end(sessionID: String, immediately: Bool = true) async {
        guard let activity = activity(sessionID: sessionID) else { return }
        await end(sessionID: sessionID, final: activity.content.state, immediately: immediately)
    }

    /// Revocation is authoritative even when the latest snapshot is unavailable.
    /// Each activity keeps its own last displayed content for a truthful end state.
    public func endAllForRevocation() async {
        let activities = Activity<QuotaActivityAttributes>.activities
        for activity in activities {
            tokenTasks.removeValue(forKey: activity.attributes.sessionID)?.cancel()
            dismissalTasks.removeValue(forKey: activity.attributes.sessionID)?.cancel()
            await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            await tokenRegistrar.endActivity(sessionID: activity.attributes.sessionID)
            onActivityStateChanged?(activity.attributes)
        }
    }

    private func activity(sessionID: String) -> Activity<QuotaActivityAttributes>? {
        Activity<QuotaActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }
    }

    /// Reattach to running activities only. System-ended or user-dismissed cards
    /// are never restarted, extended or removed from the Lock Screen by recovery.
    public func recoverExistingActivities() {
        for activity in Activity<QuotaActivityAttributes>.activities {
            guard Self.isRunning(activity) else {
                removeObservers(for: activity.attributes.sessionID)
                Task { await tokenRegistrar.endActivity(sessionID: activity.attributes.sessionID) }
                continue
            }
            guard tokenTasks[activity.attributes.sessionID] == nil else { continue }
            observe(activity)
        }
    }

    private func observe(_ activity: Activity<QuotaActivityAttributes>) {
        let sessionID = activity.attributes.sessionID
        let registrar = tokenRegistrar
        tokenTasks[sessionID] = Task {
            for await token in activity.pushTokenUpdates { await registrar.replacePushToken(token, sessionID: sessionID) }
        }
        dismissalTasks[sessionID] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                self?.onActivityStateChanged?(activity.attributes)
                switch state {
                case .dismissed, .ended:
                    await registrar.endActivity(sessionID: sessionID)
                    self?.removeObservers(for: sessionID)
                    return
                case .active, .stale, .pending: continue
                @unknown default: continue
                }
            }
        }
    }

    private func removeObservers(for sessionID: String) {
        tokenTasks.removeValue(forKey: sessionID)?.cancel()
        dismissalTasks.removeValue(forKey: sessionID)?.cancel()
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct AmmoLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaActivityAttributes.self) { context in
            ActivityQuotaView(attributes: context.attributes, state: context.state, systemIsStale: context.isStale)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .id(context.isStale)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(activityURL(windowID: context.attributes.windowID))
        } dynamicIsland: { context in
            let presentation = ActivityStatusPresentation(state: context.state, endsAt: context.attributes.endsAt, systemIsStale: context.isStale)
            let providerID = activityProviderID(context.state.label)
            let identity = ProviderCatalog.identity(for: providerID)
            let options = context.attributes.displayOptions ?? ActivityDisplayOptions()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityProviderMark(providerID: providerID)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        if options.showWindowName {
                            Text(activityWindowName(context.state.label))
                                .font(.caption2)
                                .foregroundStyle(Color(white: 0.72))
                                .lineLimit(1)
                        }
                    }
                    .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(presentation.number)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(presentation.visualState.color(for: .dark))
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if options.showProgress {
                            ActivityProgressBar(presentation: presentation, style: options.displayStyle, compact: true)
                        }
                        HStack(spacing: 6) {
                            Label(presentation.status, systemImage: presentation.symbol)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let observedAt = context.state.observedAt {
                                Text(L("widget.activity.observed.short", Date(timeIntervalSince1970: Double(observedAt)).formatted(date: .omitted, time: .shortened)))
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.72))
                        .lineLimit(1)
                    }
                    .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                ActivityCompactMark(
                    providerID: providerID,
                    presentation: presentation,
                    style: options.compactStyle
                )
            } compactTrailing: {
                Text(identity.shortName)
                    .font(.caption2.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: 48)
            } minimal: {
                ActivityCompactMark(
                    providerID: providerID,
                    presentation: presentation,
                    style: options.compactStyle
                )
            }
            .keylineTint(presentation.visualState.color(for: .dark))
            .widgetURL(activityURL(windowID: context.attributes.windowID))
        }
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct ActivityQuotaView: View {
    let attributes: QuotaActivityAttributes
    let state: QuotaActivityAttributes.ContentState
    let systemIsStale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let providerID = activityProviderID(state.label)
        let identity = ProviderCatalog.identity(for: providerID)
        let presentation = ActivityStatusPresentation(state: state, endsAt: attributes.endsAt, systemIsStale: systemIsStale)
        let style = attributes.displayOptions?.displayStyle ?? .calibrated
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ActivityProviderMark(providerID: providerID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(identity.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if attributes.displayOptions?.showWindowName ?? true {
                        Text(activityWindowName(state.label)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                ActivityNumber(presentation: presentation).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(presentation.visualState.color(for: scheme))
            }
            if attributes.displayOptions?.showProgress ?? true {
                ActivityProgressBar(presentation: presentation, style: style, compact: false)
            }
            HStack {
                Label(presentation.status, systemImage: presentation.symbol)
                Spacer()
                if let observedAt = state.observedAt {
                    Text(L("widget.activity.observed.short", Date(timeIntervalSince1970: Double(observedAt)).formatted(date: .omitted, time: .shortened)))
                }
            }.font(.caption2).foregroundStyle(presentation.visualState.color(for: scheme)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("widget.a11y.activity", identity.displayName, activityWindowName(state.label), presentation.number, presentation.status))
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct ActivityProviderMark: View {
    let providerID: String

    var body: some View {
        let identity = ProviderCatalog.identity(for: providerID)
        ProviderBrandAsset(providerID: providerID)
            .frame(width: 11, height: 11)
            .foregroundColor(identity.tone.color)
            .frame(width: 22, height: 22)
            .background(identity.tone.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(identity.displayName)
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct ActivityCompactMark: View {
    let providerID: String
    let presentation: ActivityStatusPresentation

    let style: ActivityCompactStyle

    var body: some View {
        ActivityQuotaGauge(number: presentation.number, remainingBps: presentation.remainingBps,
                           color: presentation.visualState.color(for: .dark), style: style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("widget.a11y.compact", ProviderCatalog.identity(for: providerID).displayName, presentation.number, presentation.status))
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct ActivityNumber: View {
    let presentation: ActivityStatusPresentation

    var body: some View {
        Text(presentation.number)
            .monospacedDigit()
            .accessibilityLabel(L("widget.a11y.number", presentation.number, presentation.status))
    }
}

private struct ActivityProgressBar: View {
    let presentation: ActivityStatusPresentation
    let style: QuotaDisplayStyle
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            switch style {
            case .calibrated:
                HStack(spacing: 2) {
                    ForEach(0..<20, id: \.self) { index in
                        Capsule()
                            .fill(index < (presentation.remainingBps ?? 0) / 500 ? presentation.visualState.color(for: scheme) : Color.secondary.opacity(0.22))
                    }
                }
            case .contour:
                ZStack {
                    Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    if let bps = presentation.remainingBps {
                        Capsule()
                            .trim(from: 0, to: CGFloat(bps) / 10_000)
                            .stroke(presentation.visualState.color(for: scheme), lineWidth: 1)
                    }
                }
            // The expanded island bar stays a bar; the ring shows on widgets and cards.
            case .soft, .ring:
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.22))
                    if let bps = presentation.remainingBps {
                        Capsule()
                            .fill(presentation.visualState.color(for: scheme))
                            .frame(width: proxy.size.width * CGFloat(bps) / 10_000)
                    }
                }
            }
        }
        .frame(height: style == .calibrated ? (compact ? 5 : 7) : (compact ? 7 : 9))
        .accessibilityHidden(true)
    }
}

private func activityProviderID(_ label: String) -> String {
    label.components(separatedBy: " · ").first.map { String($0.prefix(64)) } ?? label
}

private func activityWindowName(_ label: String) -> String {
    let components = label.components(separatedBy: " · ")
    return components.dropFirst().joined(separator: " · ").isEmpty ? L("widget.window.default") : components.dropFirst().joined(separator: " · ")
}

private func activityURL(windowID: String) -> URL? {
    URL(string: "quotaisland://window/" + windowID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
}
#endif
