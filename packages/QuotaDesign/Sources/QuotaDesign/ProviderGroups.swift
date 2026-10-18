import SwiftUI
import QuotaCore

/// Provider-level grouping for compact surfaces: every window of one provider
/// merges into a single block regardless of account, while snapshot order is
/// preserved both between groups and inside them (data-truth rule 3.5 — never
/// reordered by remaining size).
public struct QuotaProviderGroup: Identifiable, Sendable {
    public let id: String
    public let providerID: String
    public let values: [QuotaPresentation]

    public init(providerID: String, values: [QuotaPresentation]) {
        self.providerID = providerID
        self.values = values
        self.id = providerID
    }

    /// Windows merge across accounts of the same provider. Hiding is by
    /// provider so a hidden provider leaves the surface entirely.
    public static func groups(_ values: [QuotaPresentation], hiddenProviderIDs: Set<String> = []) -> [QuotaProviderGroup] {
        var order: [String] = []
        var buckets: [String: [QuotaPresentation]] = [:]
        for value in values {
            let providerID = value.window.providerId
            if buckets[providerID] == nil { order.append(providerID) }
            buckets[providerID, default: []].append(value)
        }
        return order.compactMap { providerID in
            guard hiddenProviderIDs.contains(providerID) == false,
                  let bucket = buckets[providerID] else { return nil }
            return QuotaProviderGroup(providerID: providerID, values: bucket)
        }
    }

    /// Windows with a real 0–100 scale; the only honest input for ring marks.
    public var percentValues: [QuotaPresentation] {
        values.filter { $0.window.unit == .percent }
    }

    /// When a provider block spans several accounts, windows regroup under
    /// their accounts in first-appearance order (same-account windows stay
    /// adjacent, data-truth rule 3.5); empty for single-account blocks.
    /// Alias may repeat across accounts — callers decide whether to repeat
    /// the same label.
    public var accountSections: [(alias: String, values: [QuotaPresentation])] {
        var order: [String] = []
        var buckets: [String: [QuotaPresentation]] = [:]
        var aliases: [String: String] = [:]
        for value in values {
            let accountID = value.window.accountId
            if buckets[accountID] == nil { order.append(accountID) }
            aliases[accountID] = value.window.accountAlias
            buckets[accountID, default: []].append(value)
        }
        guard order.count > 1 else { return [] }
        return order.map { (aliases[$0] ?? $0, buckets[$0] ?? []) }
    }
}

/// Concentric progress rings — one ring per percent window of a provider
/// block, outermost first (up to three). Rings never average or merge windows:
/// each trim is that window's own remaining share on its own 0–100 scale.
public struct QuotaRingCluster: View {
    private let values: [QuotaPresentation]
    private let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ values: [QuotaPresentation], diameter: CGFloat = 32) {
        self.values = values
        self.diameter = diameter
    }

    public var body: some View {
        let percentValues = values.filter { $0.window.unit == .percent }
        let rings = percentValues.prefix(3)
        let stroke = max(2, diameter * 0.08)
        let step = (stroke + max(1.5, diameter * 0.05)) * 2
        let animated = percentValues.map { $0.visibleBps ?? -1 }
        ZStack {
            if rings.isEmpty {
                Circle().stroke(PaperInk(scheme).track, lineWidth: stroke)
                Circle()
                    .fill(PaperInk(scheme).muted.opacity(0.7))
                    .frame(width: diameter * 0.18, height: diameter * 0.18)
            } else {
                ForEach(Array(rings.enumerated()), id: \.element.window.id) { index, value in
                    let progress = QuotaEdgeMotionPolicy.progress(for: value) ?? 0
                    let color = QuotaVisualState(value).color(for: scheme)
                    let size = diameter - CGFloat(index) * step
                    ZStack {
                        Circle().stroke(PaperInk(scheme).track, lineWidth: stroke)
                        if progress > 0 {
                            Circle().trim(from: 0, to: progress)
                                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                    }
                    .frame(width: size, height: size)
                    .opacity(QuotaVisualState(value) == .historical ? 0.5 : 1)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : QuotaMotion.gentleSpring, value: animated)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rings.map(\.window.shortDisplayName).joined(separator: ", "))
    }
}

/// The per-window circular mark of the ring grammar: a filled mini ring for
/// windows with a 0–100 scale, a quiet center-dot ring for windows without
/// one (balances, resets) — presence without a fake progress.
public struct QuotaWindowMark: View {
    private let value: QuotaPresentation
    private let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ value: QuotaPresentation, diameter: CGFloat = 13) {
        self.value = value
        self.diameter = diameter
    }

    public var body: some View {
        let stroke = max(1.5, diameter * 0.15)
        ZStack {
            Circle().stroke(PaperInk(scheme).track, lineWidth: stroke)
            if let bps = value.visibleBps, value.window.unit == .percent {
                let progress = QuotaEdgeMotionPolicy.progress(for: value) ?? 0
                if progress > 0 {
                    Circle().trim(from: 0, to: progress)
                        .stroke(QuotaVisualState(value).color(for: scheme),
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : QuotaMotion.gentleSpring, value: bps)
                }
            } else {
                Circle()
                    .fill(PaperInk(scheme).muted.opacity(0.7))
                    .frame(width: diameter * 0.28, height: diameter * 0.28)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(QuotaVisualState(value) == .historical ? 0.5 : 1)
        .accessibilityHidden(true)
    }
}
