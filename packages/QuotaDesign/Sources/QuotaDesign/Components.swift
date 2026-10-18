import SwiftUI
import QuotaCore

public struct PaperInk {
    /// `signal` is the Dot Orbit anchor orange: the start dot of every orbit and
    /// the fill of a low reading. It never marks a normal progress value.
    public let canvas, surface, elevated, ink, muted, divider, track, accent, warning, signal: Color

    public var strong: Color { ink }

    public init(_ scheme: ColorScheme) {
        let colors: [UInt32] = scheme == .dark
            ? [0x111310, 0x1B1E1A, 0x242822, 0xF4F3ED, 0xA7ADA3, 0x30362F, 0x30362F, 0xB6CDB8, 0xF19B82, 0xFF7A3D]
            : [0xF3F2ED, 0xFAF9F5, 0xFFFFFF, 0x20231F, 0x676D65, 0xE7E8E2, 0xE7E8E2, 0x506956, 0xA84432, 0xF2561D]
        let c = colors.map {
            Color(red: Double(($0 >> 16) & 255) / 255,
                  green: Double(($0 >> 8) & 255) / 255,
                  blue: Double($0 & 255) / 255)
        }
        (canvas, surface, elevated, ink, muted, divider, track, accent, warning, signal) =
            (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9])
    }
}

public extension ProviderTone {
    var color: Color { color(for: .light) }

    func color(for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return switch self {
            case .teal: Color(red: 0.25, green: 0.79, blue: 0.72)
            case .terracotta: Color(red: 0.95, green: 0.52, blue: 0.36)
            case .blue: Color(red: 0.42, green: 0.64, blue: 0.96)
            case .violet: Color(red: 0.68, green: 0.57, blue: 0.96)
            case .moss: Color(red: 0.55, green: 0.73, blue: 0.57)
            case .amber: Color(red: 0.96, green: 0.68, blue: 0.28)
            }
        }
        return switch self {
        case .teal: Color(red: 0.12, green: 0.55, blue: 0.51)
        case .terracotta: Color(red: 0.78, green: 0.38, blue: 0.25)
        case .blue: Color(red: 0.24, green: 0.48, blue: 0.82)
        case .violet: Color(red: 0.50, green: 0.39, blue: 0.77)
        case .moss: Color(red: 0.34, green: 0.48, blue: 0.36)
        case .amber: Color(red: 0.82, green: 0.53, blue: 0.16)
        }
    }
}

public enum QuotaMotion {
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.9)
    public static let gentleSpring = Animation.spring(response: 0.34, dampingFraction: 0.96)
}

public struct ProviderMark: View {
    private let identity: ProviderIdentity
    private let size: CGFloat
    private let selected: Bool
    private let glyphFraction: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(providerID: String, size: CGFloat = 28, selected: Bool = false, glyphFraction: CGFloat = 0.48) {
        identity = ProviderCatalog.identity(for: providerID)
        self.size = size
        self.selected = selected
        self.glyphFraction = glyphFraction
    }

    public var body: some View {
        let tone = identity.tone.color(for: scheme)
        ProviderBrandAsset(providerID: identity.id)
            .frame(width: size * glyphFraction, height: size * glyphFraction)
            .foregroundColor(selected ? .white : tone)
            .frame(width: size, height: size)
            .background(selected ? tone : tone.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                    .stroke(tone.opacity(selected ? 0 : 0.18), lineWidth: 0.5)
            }
            .accessibilityLabel(identity.displayName)
    }
}

public struct ProviderBadge: View {
    private let identity: ProviderIdentity
    private let showsName: Bool

    public init(providerID: String, showsName: Bool = true) {
        identity = ProviderCatalog.identity(for: providerID)
        self.showsName = showsName
    }

    public var body: some View {
        HStack(spacing: 7) {
            ProviderMark(providerID: identity.id, size: 26)
            if showsName {
                Text(identity.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(identity.displayName)
    }
}

public struct QuotaAccountGroup: Identifiable, Sendable {
    public let id: String
    public let providerID: String
    public let accountAlias: String
    public let values: [QuotaPresentation]

    public init(providerID: String, accountAlias: String, values: [QuotaPresentation], id: String) {
        self.providerID = providerID
        self.accountAlias = accountAlias
        self.values = values
        self.id = id
    }

    public static func grouped(_ values: [QuotaPresentation]) -> [QuotaAccountGroup] {
        var order: [String] = []
        var buckets: [String: [QuotaPresentation]] = [:]
        for value in values {
            let key = value.window.providerId + "\u{1F}" + value.window.accountId
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(value)
        }
        return order.compactMap { key in
            guard let bucket = buckets[key], let first = bucket.first else { return nil }
            return QuotaAccountGroup(providerID: first.window.providerId,
                                     accountAlias: first.window.accountAlias,
                                     values: bucket,
                                     id: key)
        }
    }
}

public struct ProviderQuotaBar: View {
    private let value: QuotaPresentation
    private let identity: ProviderIdentity
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ value: QuotaPresentation) {
        self.value = value
        identity = ProviderCatalog.identity(for: value.window.providerId)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PaperInk(scheme).track)
                if let bps = value.visibleBps {
                    Capsule()
                        .fill(QuotaVisualState(value).color(for: scheme))
                        .frame(width: max(0, proxy.size.width * CGFloat(bps) / 10_000))
                        .animation(reduceMotion ? nil : QuotaMotion.gentleSpring, value: bps)
                }
            }
        }
        .frame(height: 7)
        .accessibilityLabel(value.visibleBps == nil ? L("design.a11y.noRatio") : "\(value.valueHeading) \(value.number)")
    }
}

public struct QuotaLimitRow: View {
    private let value: QuotaPresentation
    private let selected: Bool
    private let action: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ value: QuotaPresentation, selected: Bool = false, action: (() -> Void)? = nil) {
        self.value = value
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("design.a11y.limitRow", value.window.shortDisplayName, "\(value.valueHeading) \(value.number)", value.status))
    }

    private var content: some View {
        let palette = PaperInk(scheme)
        return VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.window.shortDisplayName)
                        .studioType(.body).fontWeight(.semibold)
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(resetDescription(value, now: context.date))
                            .studioType(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                    if value.isHistorical {
                        // Missing reset information already falls back to this status.
                        if resetDescription(value, now: Date()) != value.status {
                            Text(value.status)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(palette.muted)
                        }
                        if let observed = value.window.observedAt.flatMap(QuotaRules.date) {
                            Text(L("design.observedAt", observed.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption2)
                                .foregroundStyle(palette.muted)
                        }
                    }
                }
                Spacer(minLength: 10)
                Text(value.number)
                    .studioType(.section)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .help(value.window.amount ?? value.number)
                    .contentTransition(.numericText())
                    .foregroundStyle(QuotaVisualState(value).color(for: scheme))
            }
            if value.visibleBps != nil {
                ProviderQuotaBar(value)
            } else if value.window.unit == .money {
                Label(L("design.noQuotaCap"), systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(selected ? ProviderCatalog.identity(for: value.window.providerId).tone.color(for: scheme).opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(reduceMotion ? nil : QuotaMotion.spring, value: selected)
    }
}

public struct ProviderQuotaPanel: View {
    private let group: QuotaAccountGroup
    private let showsTrend: Bool
    @Binding private var selectedWindowID: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(group: QuotaAccountGroup, selectedWindowID: Binding<String?>, showsTrend: Bool = true) {
        self.group = group
        _selectedWindowID = selectedWindowID
        self.showsTrend = showsTrend
    }

    public var body: some View {
        let palette = PaperInk(scheme)
        let selected = group.values.first(where: { $0.window.id == selectedWindowID }) ?? group.values.first
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderMark(providerID: group.providerID, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ProviderCatalog.identity(for: group.providerID).displayName).studioType(.section)
                    Text(group.accountAlias).studioType(.caption).foregroundStyle(palette.muted).lineLimit(1)
                }
                Spacer()
                Text(L("design.itemCount", group.values.count))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.muted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], spacing: 8) {
                ForEach(group.values, id: \.window.id) { value in
                    QuotaLimitRow(value, selected: selectedWindowID == value.window.id) {
                        withAnimation(reduceMotion ? nil : QuotaMotion.spring) {
                            selectedWindowID = value.window.id
                        }
                    }
                }
            }

            if showsTrend, let selected, selected.visibleBps != nil {
                StudioDivider()
                QuotaTrend(selected, chartHeight: 62, spacing: 7)
                    .foregroundStyle(ProviderCatalog.identity(for: group.providerID).tone.color(for: scheme))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if !showsTrend, let selected, selected.visibleBps != nil {
                DisclosureGroup(L("design.trendDisclosure", selected.window.shortDisplayName)) {
                    QuotaTrend(selected, chartHeight: 70, spacing: 8).padding(.top, 10)
                }.studioType(.caption).foregroundStyle(palette.muted)
            }
        }
        .padding(16)
        .foregroundStyle(palette.ink)
        .studioSurface()
    }
}

public struct QuotaSummaryCard: View {
    private let value: QuotaPresentation
    @State private var selection: String?

    public init(_ value: QuotaPresentation) {
        self.value = value
        _selection = State(initialValue: value.window.id)
    }

    public var body: some View {
        ProviderQuotaPanel(
            group: QuotaAccountGroup(providerID: value.window.providerId,
                                     accountAlias: value.window.accountAlias,
                                     values: [value],
                                     id: value.window.providerId + "\u{1F}" + value.window.accountId),
            selectedWindowID: $selection,
            showsTrend: false
        )
    }
}

public struct WindowLabel: View {
    let value: QuotaPresentation
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProviderBadge(providerID: value.window.providerId)
                Spacer(minLength: 8)
                Text(value.window.shortDisplayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value.window.accountAlias).font(.headline)
        }
    }
}

public struct QuotaNumber: View {
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 48.0
    @Environment(\.colorScheme) private var scheme
    let value: QuotaPresentation
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.valueHeading).font(.caption)
            Text(value.number).font(.system(size: numberSize, weight: .semibold)).monospacedDigit()
                .foregroundStyle(QuotaVisualState(value).color(for: scheme))
        }
    }
}

public struct QuotaRuler: View {
    let value: QuotaPresentation
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View { ProviderQuotaBar(value).frame(height: 8) }
}

public struct QuotaGauge: View {
    let value: QuotaPresentation
    @Environment(\.colorScheme) private var scheme
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View {
        if let bps = value.visibleBps {
            ZStack {
                Circle().stroke(PaperInk(scheme).track, lineWidth: 8)
                Circle().trim(from: 0, to: Double(bps) / 10_000)
                    .stroke(QuotaVisualState(value).color(for: scheme),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            Text("—")
        }
    }
}

public struct ResetLabel: View {
    let value: QuotaPresentation
    let compact: Bool
    public init(_ value: QuotaPresentation, compact: Bool = false) {
        self.value = value
        self.compact = compact
    }
    public var body: some View {
        if value.state == .authRequired {
            // Updates are paused; the freshness badge beside this label already says why.
            EmptyView()
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(resetDescription(value, now: context.date, compact: compact))
            }
        }
    }
}

public struct FreshnessBadge: View {
    let value: QuotaPresentation
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View {
        Label(value.status, systemImage: QuotaVisualState(value).symbol)
            .font(.caption)
    }
}

public struct ProviderRow: View {
    let value: QuotaPresentation
    public init(_ value: QuotaPresentation) { self.value = value }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WindowLabel(value)
            QuotaNumber(value)
            if value.visibleBps != nil {
                ProviderQuotaBar(value)
            } else if value.window.unit == .money {
                Text(L("design.noQuotaCap"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack { FreshnessBadge(value); Spacer(); ResetLabel(value) }.font(.caption)
        }
    }
}

public struct QuotaTrend: View {
    let segments: [[HistoryPoint]]
    let chartHeight: CGFloat
    let spacing: CGFloat

    public init(_ value: QuotaPresentation, chartHeight: CGFloat = 96, spacing: CGFloat = 8) {
        segments = value.state == .locked ? [] : QuotaRules.trendSegments(value.window.history)
        self.chartHeight = chartHeight
        self.spacing = spacing
    }

    public var body: some View {
        let points = segments.flatMap { $0 }
        let dates = points.compactMap { QuotaRules.date($0.observedAt)?.timeIntervalSince1970 }
        VStack(alignment: .leading, spacing: spacing) {
            HStack {
                Label(L("design.trendTitle"), systemImage: "chart.xyaxis.line").font(.caption.weight(.semibold))
                Spacer()
                Text("0–100%").font(.caption2).foregroundStyle(.secondary)
            }
            if let first = dates.min(), let last = dates.max(), last > first {
                Canvas { context, size in
                    let guides = Path { path in
                        for fraction in [0.25, 0.5, 0.75] {
                            let y = size.height * fraction
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    context.stroke(guides, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                    for segment in segments {
                        var path = Path()
                        for (index, point) in segment.enumerated() {
                            guard let t = QuotaRules.date(point.observedAt)?.timeIntervalSince1970,
                                  let bps = point.remainingBps else { continue }
                            let position = CGPoint(x: (t - first) / (last - first) * size.width,
                                                   y: (1 - Double(bps) / 10_000) * size.height)
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        context.stroke(path, with: .foreground,
                                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: chartHeight)
                .accessibilityLabel(points.map { L("design.a11y.trendPoint", $0.observedAt, ($0.remainingBps ?? 0) / 100) }.joined(separator: L("design.a11y.trendSeparator")))
            } else {
                Text(L("design.trendEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: chartHeight)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

public struct SyncStatus: View {
    public init() {}
    public var body: some View {
        Label(L("design.demoNoSync"), systemImage: "desktopcomputer").font(.caption)
    }
}

public struct EmptyState: View {
    public init() {}
    public var body: some View {
        ContentUnavailableView(L("design.emptyTitle"),
                               systemImage: "gauge.with.dots.needle.33percent",
                               description: Text(L("design.emptyDescription")))
    }
}

public struct QuotaCard: View {
    let value: QuotaPresentation
    let showsTrend: Bool
    @State private var selection: String?

    public init(_ value: QuotaPresentation, showsTrend: Bool = true) {
        self.value = value
        self.showsTrend = showsTrend
        _selection = State(initialValue: value.window.id)
    }

    public var body: some View {
        ProviderQuotaPanel(
            group: QuotaAccountGroup(providerID: value.window.providerId,
                                     accountAlias: value.window.accountAlias,
                                     values: [value],
                                     id: value.window.providerId + "\u{1F}" + value.window.accountId),
            selectedWindowID: $selection,
            showsTrend: showsTrend
        )
    }
}

private func resetDescription(_ value: QuotaPresentation, now: Date, compact: Bool = false) -> String {
    if value.state == .locked { return L("design.resetLocked") }
    if value.state == .resetPending { return L("design.resetPending") }
    // A paused authorization never counts down; the status explains why instead.
    if value.state == .authRequired { return value.status }
    if let description = value.window.resetDescription(now: now, compact: compact) { return description }
    // A window with no usage and no reset has no countdown yet — Factory
    // omits the window end until the first request — so name that state
    // instead of falling back to a generic freshness status.
    if !value.isHistorical, value.window.isIdleWindow { return L("quota.reset.idleWindow") }
    return value.status
}
