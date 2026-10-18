import Combine
import Foundation
import SwiftUI
import QuotaCore

public enum QuotaAppearanceKeys {
    public static let displayStyle = "quota.display.style"
    public static let edgeMotion = "quota.display.edgeMotion"
    /// Provider IDs the user hid from the menu bar quota list (array of strings).
    public static let menuHiddenProviders = "quota.menu.hiddenProviders"
    public static let menuProvidersChanged = Notification.Name("quota.menuProvidersChanged")
    public static let islandLayoutChanged = Notification.Name("quota.islandLayoutChanged")
}

/// Stored locally on each device. Unknown future values fall back to the default.
public enum QuotaDisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case contour, calibrated, soft, ring

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .contour: L("design.style.contour")
        case .calibrated: L("design.style.calibrated")
        case .soft: L("design.style.soft")
        case .ring: L("design.style.ring")
        }
    }
    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? .calibrated }
    public init(from decoder: any Decoder) throws {
        self.init(storedValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Freshness and availability take priority over numeric thresholds on every surface.
public enum QuotaVisualState: String, Equatable, Sendable {
    case normal, low, exhausted, historical, unavailable

    public init(_ value: QuotaPresentation) {
        // An expired authorization still holds the last recorded reading, so it
        // renders with the muted historical treatment instead of "no data".
        if [.locked, .unavailable].contains(value.state) {
            self = .unavailable
        } else if value.isHistorical || value.state == .offline {
            self = .historical
        } else if value.state == .exhausted {
            self = .exhausted
        } else if value.state == .low && !value.window.isConsumptionMetric {
            self = .low
        } else {
            self = .normal
        }
    }

    public var symbol: String {
        switch self {
        case .normal: "checkmark.circle"
        case .low, .exhausted: "exclamationmark.circle"
        case .historical: "clock"
        case .unavailable: "questionmark.circle"
        }
    }

    public func color(for scheme: ColorScheme) -> Color {
        let hex: UInt32 = switch (self, scheme == .dark) {
        case (.normal, true): 0xB6CDB8
        case (.normal, false): 0x506956
        case (.low, true): 0xEAC58A
        case (.low, false): 0x865A18
        case (.exhausted, true): 0xF19B82
        case (.exhausted, false): 0xA84432
        case (.historical, true), (.unavailable, true): 0xA7ADA3
        case (.historical, false), (.unavailable, false): 0x676D65
        }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

/// Pure policy: motion is decoration, never a progress value or a freshness signal.
public enum QuotaEdgeMotionPolicy {
    public static func permitsAmbientMotion(
        value: QuotaPresentation?, style: QuotaDisplayStyle, enabled: Bool,
        reduceMotion: Bool, lowPower: Bool
    ) -> Bool {
        guard enabled, !reduceMotion, !lowPower, style == .calibrated, let value,
              let bps = value.visibleBps, bps > 0 else { return false }
        return [.normal, .low].contains(QuotaVisualState(value))
    }

    public static func progress(for value: QuotaPresentation?) -> Double? {
        guard let value, QuotaVisualState(value) != .unavailable,
              let bps = value.visibleBps else { return nil }
        return Double(min(10_000, max(0, bps))) / 10_000
    }
}

/// U-shaped on a notched Mac, a closed capsule/card perimeter elsewhere.
/// The top edge is deliberately absent when the surface touches the hardware notch.
public struct QuotaBoundaryShape: Shape {
    public var attachesToTop: Bool
    public var cornerRadius: CGFloat

    public init(attachesToTop: Bool = false, cornerRadius: CGFloat = 20) {
        self.attachesToTop = attachesToTop
        self.cornerRadius = cornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let radius = max(0, min(cornerRadius, min(inset.width, inset.height) / 2))
        var path = Path()
        if attachesToTop {
            path.move(to: CGPoint(x: inset.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: inset.minX + radius, y: inset.maxY),
                              control: CGPoint(x: inset.minX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.maxX - radius, y: inset.maxY))
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.maxY - radius),
                              control: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.maxX, y: rect.minY))
        } else {
            // Start at top center, then walk clockwise so progress does not rotate.
            path.move(to: CGPoint(x: inset.midX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX - radius, y: inset.minY))
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.minY + radius),
                              control: CGPoint(x: inset.maxX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: inset.maxX - radius, y: inset.maxY),
                              control: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX + radius, y: inset.maxY))
            path.addQuadCurve(to: CGPoint(x: inset.minX, y: inset.maxY - radius),
                              control: CGPoint(x: inset.minX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + radius))
            path.addQuadCurve(to: CGPoint(x: inset.minX + radius, y: inset.minY),
                              control: CGPoint(x: inset.minX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.midX, y: inset.minY))
            path.closeSubpath()
        }
        return path
    }
}

/// The owning app disables motion while inactive/hidden or while its shell resizes.
/// Widget/Activity surfaces use static progress and never instantiate this timeline.
public struct QuotaEdgeBorder: View {
    private let value: QuotaPresentation?
    private let style: QuotaDisplayStyle
    private let attachesToTop: Bool
    private let animationEnabled: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var feedbackStarted: Date?

    public init(value: QuotaPresentation?, style: QuotaDisplayStyle,
                attachesToTop: Bool = false, animationEnabled: Bool = true) {
        self.value = value
        self.style = style
        self.attachesToTop = attachesToTop
        self.animationEnabled = animationEnabled
    }

    private var visual: QuotaVisualState { value.map(QuotaVisualState.init) ?? .unavailable }
    private var progress: Double { QuotaEdgeMotionPolicy.progress(for: value) ?? 0 }
    private var shape: QuotaBoundaryShape {
        QuotaBoundaryShape(attachesToTop: attachesToTop, cornerRadius: style == .soft ? 26 : 20)
    }
    private var allowsAmbient: Bool {
        QuotaEdgeMotionPolicy.permitsAmbientMotion(value: value, style: style,
            enabled: animationEnabled, reduceMotion: reduceMotion, lowPower: lowPower)
    }
    private var observationKey: String {
        guard let value else { return "missing" }
        return [value.window.id, value.window.observedAt ?? "", String(value.visibleBps ?? -1), visual.rawValue].joined(separator: "|")
    }
    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: style == .soft ? 2.4 : 1.8, lineCap: .butt,
                    dash: style == .calibrated || visual == .historical || visual == .unavailable ? [4, 3] : [])
    }

    public var body: some View {
        ZStack {
            shape.stroke(visual.color(for: scheme).opacity(0.23), style: stroke)
            if progress > 0 {
                shape.trim(from: 0, to: progress)
                    .stroke(visual.color(for: scheme).opacity(visual == .historical ? 0.42 : 0.82), style: stroke)
            }
            if allowsAmbient || (feedbackStarted != nil && animationEnabled && !reduceMotion && !lowPower) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    animatedHighlight(at: context.date)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The system posts power-state changes on a background queue (the
        // documented cause of the Sep 5 launch crash); hop to main so the
        // @State write can never publish off the main thread.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: observationKey) { old, new in
            guard old != new, animationEnabled, !reduceMotion, !lowPower,
                  [.normal, .low, .exhausted].contains(visual) else { feedbackStarted = nil; return }
            feedbackStarted = .now
        }
        .task(id: feedbackStarted) {
            guard feedbackStarted != nil else { return }
            try? await Task.sleep(for: .milliseconds(950))
            if !Task.isCancelled { feedbackStarted = nil }
        }
    }

    @ViewBuilder
    private func animatedHighlight(at date: Date) -> some View {
        let color = visual.color(for: scheme)
        let feedback = feedbackStarted.map { date.timeIntervalSince($0) }
        if let feedback, feedback >= 0, feedback < 0.7, [.low, .exhausted].contains(visual) {
            shape.stroke(color.opacity(sin(feedback / 0.7 * .pi) * 0.7), style: stroke)
        } else if progress > 0 {
            let position = feedback.map { min(1, max(0, $0 / 0.9)) }
                ?? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6.4) / 6.4
            let end = min(progress, position)
            let start = min(progress, max(0, position - 0.08))
            if end > start {
                shape.trim(from: start, to: end)
                    .stroke(scheme == .dark ? Color.white.opacity(0.9) : color, style: StrokeStyle(lineWidth: 2.6))
                    .mask(shape.stroke(.white, style: stroke))
            }
        }
    }
}

/// Fixed positions for every tick; changes never stretch or shuffle the scale.
public struct QuotaStyledProgress: View {
    private let value: QuotaPresentation
    private let style: QuotaDisplayStyle
    private let height: CGFloat?
    @Environment(\.colorScheme) private var scheme

    public init(value: QuotaPresentation, style: QuotaDisplayStyle, height: CGFloat? = nil) {
        self.value = value
        self.style = style
        self.height = height
    }

    public var body: some View {
        let visual = QuotaVisualState(value)
        let progress = QuotaEdgeMotionPolicy.progress(for: value) ?? 0
        GeometryReader { proxy in
            let ticks = max(1, Int(proxy.size.width / 7))
            ZStack(alignment: .leading) {
                if style == .calibrated {
                    HStack(spacing: 3) {
                        ForEach(0..<ticks, id: \.self) { _ in Rectangle().fill(PaperInk(scheme).track) }
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<ticks, id: \.self) { _ in Rectangle().fill(visual.color(for: scheme)) }
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: proxy.size.width * progress) }
                } else if style == .contour {
                    Capsule().strokeBorder(visual.color(for: scheme).opacity(0.3), lineWidth: 0.75)
                    if progress > 0 {
                        Capsule().fill(visual.color(for: scheme))
                            .frame(width: proxy.size.width * progress, height: 1.5)
                    }
                } else {
                    Capsule().fill(PaperInk(scheme).track)
                    if progress > 0 {
                        Capsule().fill(visual.color(for: scheme)).frame(width: proxy.size.width * progress)
                    }
                }
            }
            .opacity(visual == .historical ? 0.5 : 1)
        }
        .frame(height: height ?? (style == .calibrated ? 12 : style == .soft ? 7 : 3))
        .accessibilityLabel(value.visibleBps == nil ? L("design.a11y.noRatio") : "\(value.valueHeading) \(value.number)")
    }
}

/// Circular progress with the reading centered — the ring shape of the display
/// style, for surfaces where a horizontal bar does not fit the layout.
public struct QuotaRingGauge: View {
    private let value: QuotaPresentation
    private let diameter: CGFloat
    private let showsNumber: Bool
    @Environment(\.colorScheme) private var scheme

    public init(value: QuotaPresentation, diameter: CGFloat = 44, showsNumber: Bool = true) {
        self.value = value
        self.diameter = diameter
        self.showsNumber = showsNumber
    }

    public var body: some View {
        let visual = QuotaVisualState(value)
        let progress = QuotaEdgeMotionPolicy.progress(for: value) ?? 0
        ZStack {
            Circle().stroke(PaperInk(scheme).track, lineWidth: diameter >= 40 ? 3 : 2)
            if progress > 0 {
                Circle().trim(from: 0, to: progress)
                    .stroke(visual.color(for: scheme), style: StrokeStyle(lineWidth: diameter >= 40 ? 3 : 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showsNumber {
                Text(value.number)
                    .font(.system(size: diameter * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    .padding(.horizontal, diameter * 0.14)
            }
        }
        .foregroundStyle(visual.color(for: scheme))
        .frame(width: diameter, height: diameter)
        .opacity(visual == .historical ? 0.5 : 1)
        .accessibilityLabel(value.visibleBps == nil ? L("design.a11y.noRatio") : "\(value.valueHeading) \(value.number)")
    }
}

/// Dot Orbit: evenly spaced dots read clockwise from 12 o'clock. Solid dots are
/// what remains, hollow dots are spent, and the larger signal dot at the top
/// anchors the reading so an empty or full orbit still shows where it starts.
/// The dot count is fixed per size, so a changing value never reflows the ring.
public struct QuotaDotOrbit: View {
    private let progress: Double?
    private let dots: Int
    private let fill: Color
    private let hollow: Color
    private let anchor: Color
    private let label: String

    /// Primitive form for surfaces that hold only a ratio and a tone, such as
    /// Live Activity content. `progress` is 0...1, or nil when no ratio exists.
    public init(progress: Double?, dots: Int = 40, fill: Color, hollow: Color, anchor: Color, accessibilityLabel: String) {
        self.progress = progress.map { min(1, max(0, $0)) }
        self.dots = max(8, dots)
        self.fill = fill
        self.hollow = hollow
        self.anchor = anchor
        label = accessibilityLabel
    }

    /// Freshness and availability win over the numeric tone, as on every surface:
    /// a low reading turns the solid dots signal orange, a historical one mutes them.
    public init(value: QuotaPresentation, dots: Int = 40, scheme: ColorScheme) {
        let palette = PaperInk(scheme)
        let visual = QuotaVisualState(value)
        let fill: Color = switch visual {
        case .normal: palette.ink
        case .low: palette.signal
        case .exhausted: palette.warning
        case .historical, .unavailable: palette.muted
        }
        let anchor: Color = switch visual {
        case .normal, .low: palette.signal
        case .exhausted: palette.warning
        case .historical: palette.muted
        case .unavailable: palette.muted.opacity(0.45)
        }
        self.init(progress: QuotaEdgeMotionPolicy.progress(for: value), dots: dots,
                  fill: fill, hollow: palette.muted.opacity(0.42), anchor: anchor,
                  accessibilityLabel: value.visibleBps == nil ? L("design.a11y.noRatio") : "\(value.valueHeading) \(value.number)")
    }

    public var body: some View {
        Canvas { context, size in
            let count = dots
            let outer = min(size.width, size.height) / 2
            let step = 2 * .pi * outer / CGFloat(count)
            let dot = step * 0.5
            let marker = dot * 1.6
            let radius = outer - marker / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let solid = progress.map { p in p > 0 ? max(1, Int((p * Double(count)).rounded())) : 0 } ?? 0
            let line = max(0.75, dot * 0.2)
            for index in 0..<count {
                let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if index == 0 {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - marker / 2, y: point.y - marker / 2, width: marker, height: marker)),
                                 with: .color(anchor))
                } else if index < solid {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                                 with: .color(fill))
                } else {
                    let d = dot - line
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)),
                                   with: .color(hollow), lineWidth: line)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// Shared by the real Activity and the phone's preview; no synthetic quota values.
public struct ActivityQuotaGauge: View {
    let number: String
    let remainingBps: Int?
    let color: Color
    let style: ActivityCompactStyle

    public init(number: String, remainingBps: Int?, color: Color, style: ActivityCompactStyle) {
        self.number = number; self.remainingBps = remainingBps; self.color = color; self.style = style
    }

    public var body: some View {
        ZStack {
            if style == .ring {
                Circle().stroke(color.opacity(0.22), lineWidth: 2)
                if let remainingBps {
                    Circle().trim(from: 0, to: CGFloat(min(10_000, max(0, remainingBps))) / 10_000)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else if style == .capsule {
                Capsule().stroke(color.opacity(0.25), lineWidth: 1)
                if let remainingBps {
                    Capsule().trim(from: 0, to: CGFloat(min(10_000, max(0, remainingBps))) / 10_000)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            Text(style == .number ? number : number.replacingOccurrences(of: "%", with: ""))
                .font(.system(size: style == .number ? 12 : 10, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
        .foregroundStyle(color)
        .frame(width: style == .ring ? 28 : 36, height: 28)
        .accessibilityLabel(number)
    }
}
