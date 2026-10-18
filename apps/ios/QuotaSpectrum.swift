import SwiftUI
import QuotaCore
import QuotaDesign

/// Pure data behind the Spectrum hero: one sector per ratio window, in snapshot
/// order grouped by provider. Windows without a 0–100 ratio never appear, and
/// nothing here averages or re-sorts windows.
struct QuotaSpectrumModel {
    static let expiringHorizon: TimeInterval = 24 * 3600
    static let expiringMinimumBps = 3_000

    enum Countdown: Equatable {
        case minutes(Int), hours(Int)

        /// Under one hour reads in minutes, otherwise in hours, both rounded;
        /// 59m30s therefore reads "1h" rather than "60m".
        init(_ interval: TimeInterval) {
            let minutes = Int((max(interval, 0) / 60).rounded())
            self = minutes < 60 ? .minutes(max(minutes, 1)) : .hours(Int((interval / 3600).rounded()))
        }

        var text: String {
            switch self {
            case .minutes(let n): L("phone.spectrum.minutes", n)
            case .hours(let n): L("phone.spectrum.hours", n)
            }
        }
    }

    struct Entry {
        let value: QuotaPresentation
        let remainingBps: Int
        let resetsAt: Date?
        let countdown: Countdown?
        let startsProvider: Bool
        var isExpiring: Bool { countdown != nil }
        var id: String { value.window.id }
        var providerName: String { ProviderCatalog.identity(for: value.window.providerId).displayName }
    }

    let entries: [Entry]
    /// Expiring windows, soonest reset first.
    let expiring: [Entry]

    init(_ values: [QuotaPresentation], now: Date) {
        var built: [Entry] = []
        for group in QuotaProviderGroup.groups(values) {
            for value in group.values {
                // Money budgets can carry bps too; only percentage quotas are drawn as rays.
                guard value.window.unit == .percent, let bps = value.visibleBps else { continue }
                let reset = value.window.window.resetsAt.flatMap(QuotaRules.date)
                let expiring = !value.isHistorical && bps >= Self.expiringMinimumBps
                    && reset.map { $0 > now && $0.timeIntervalSince(now) < Self.expiringHorizon } == true
                built.append(Entry(value: value, remainingBps: bps, resetsAt: reset,
                                   countdown: expiring ? reset.map { Countdown($0.timeIntervalSince(now)) } : nil,
                                   startsProvider: !built.contains { $0.value.window.providerId == group.providerID }))
            }
        }
        entries = built
        expiring = built.filter(\.isExpiring).sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    var isEmpty: Bool { entries.isEmpty }

    static func raysPerSector(_ count: Int) -> Int { min(max(160 / max(count, 1), 3), 12) }

    /// Gentle deterministic length multiplier in 0.82...1.0.
    static func jitter(sector: Int, ray: Int) -> Double { 0.91 + 0.09 * sin(Double(ray) * 1.9 + Double(sector)) }

    var accessibilitySummary: String {
        guard !expiring.isEmpty else { return L("phone.spectrum.a11y.steady", entries.count) }
        let names = expiring.map { "\($0.providerName) \($0.value.window.shortDisplayName) \($0.countdown?.text ?? "")" }
        return L("phone.spectrum.a11y.expiring", entries.count, expiring.count, names.joined(separator: ", "))
    }
}

/// Hero visualization: a circle of radial hairlines, one sector per window, ray
/// length proportional to that window's own remaining share. Only expiring
/// sectors use the signal color and flicker. Tapping a sector names it in the
/// center; tapping the center then opens that window's details.
struct QuotaSpectrumView: View {
    let model: QuotaSpectrumModel
    let onSelect: (String) -> Void
    @State private var selectedID: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sector layout shared by drawing and hit testing, in canvas points.
    struct Geometry {
        let center: CGPoint, unit: Double, inner: Double, span: Double
        /// Start angle and angular width per entry, clockwise from 12 o'clock.
        let sectors: [(start: Double, width: Double)]

        init(_ model: QuotaSpectrumModel, size: CGSize) {
            unit = min(size.width, size.height) / 292
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            inner = 48 * unit; span = 72 * unit
            let n = model.entries.count
            let providerGaps = model.entries.filter(\.startsProvider).count
            let sectorGap = 0.03, providerGap = 0.07
            // A provider start uses providerGap in place of sectorGap, so each entry carries exactly one gap.
            let width = max((2 * .pi - Double(n - providerGaps) * sectorGap - Double(providerGaps) * providerGap) / Double(max(n, 1)), 0.01)
            var angle = -Double.pi / 2, built: [(Double, Double)] = []
            for entry in model.entries {
                let gap = entry.startsProvider ? providerGap : sectorGap
                angle += gap / 2; built.append((angle, width)); angle += width + gap / 2
            }
            sectors = built
        }

        func point(_ angle: Double, _ radius: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }

        /// Entry index under a tap on the ray band, by nearest sector midpoint.
        func sector(at location: CGPoint) -> Int? {
            let dx = location.x - center.x, dy = location.y - center.y, d = hypot(dx, dy)
            guard d >= inner - 8 * unit, d <= inner + span + 24 * unit else { return nil }
            let a = atan2(dy, dx)
            func distance(_ i: Int) -> Double { abs(remainder(a - (sectors[i].start + sectors[i].width / 2), 2 * .pi)) }
            return sectors.indices.min { distance($0) < distance($1) }
        }

        func isCenter(_ location: CGPoint) -> Bool { hypot(location.x - center.x, location.y - center.y) < inner - 6 * unit }
    }

    var body: some View {
        let palette = PaperInk(scheme)
        // A refresh can drop the selected window; only a selection still present counts.
        let selected = model.entries.first { $0.id == selectedID }
        let activeID = selected?.id
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || model.expiring.isEmpty)) { context in
            Canvas { gc, size in draw(&gc, size, palette, selectedID: activeID, time: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate) }
                .overlay { center(palette, selected) }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                    let geometry = Geometry(model, size: proxy.size)
                    if geometry.isCenter(tap.location), let activeID {
                        onSelect(activeID)
                    } else if let i = geometry.sector(at: tap.location) {
                        selectedID = activeID == model.entries[i].id ? nil : model.entries[i].id
                    } else {
                        selectedID = nil
                    }
                })
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
        .frame(maxWidth: .infinity)
        .accessibilityRepresentation {
            VStack {
                Text(model.accessibilitySummary)
                ForEach(model.entries, id: \.id) { entry in
                    Button {
                        selectedID = entry.id
                        onSelect(entry.id)
                    } label: {
                        Text("\(entry.providerName) \(entry.value.window.accountAlias) \(entry.value.window.shortDisplayName), \(entry.value.number), \(entry.value.status)")
                    }
                    .accessibilityIdentifier("phone-spectrum-" + entry.id)
                }
            }
        }
    }

    @ViewBuilder
    private func center(_ palette: PaperInk, _ selected: QuotaSpectrumModel.Entry?) -> some View {
        if let selected {
            VStack(spacing: 1) {
                Text(selected.providerName).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink)
                Text(selected.value.window.shortDisplayName).font(.caption2).foregroundStyle(palette.muted)
                Text(selected.value.number).font(.title3.weight(.light)).monospacedDigit().foregroundStyle(palette.ink)
                if selected.value.isHistorical {
                    Text(selected.value.status).font(.caption2).foregroundStyle(palette.muted)
                }
                if let countdown = selected.countdown {
                    Text(countdown.text).font(.caption2).monospacedDigit().foregroundStyle(palette.signal)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: 84)
        } else {
            let count = model.expiring.count
            Text(count == 0 ? L("phone.spectrum.allSteady") : L("phone.spectrum.expiringCount", count))
                .font(.footnote.weight(.medium))
                .foregroundStyle(count == 0 ? palette.muted : palette.signal)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 80)
        }
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, _ palette: PaperInk, selectedID: String?, time: TimeInterval?) {
        let geometry = Geometry(model, size: size)
        let unit = geometry.unit, inner = geometry.inner, span = geometry.span, center = geometry.center
        let rays = QuotaSpectrumModel.raysPerSector(model.entries.count)
        gc.stroke(Path(ellipseIn: CGRect(x: center.x - inner + 6 * unit, y: center.y - inner + 6 * unit, width: (inner - 6 * unit) * 2, height: (inner - 6 * unit) * 2)),
                  with: .color(palette.divider), lineWidth: 0.5)

        var labels: [(Double, QuotaSpectrumModel.Entry)] = []
        for (i, entry) in model.entries.enumerated() {
            let (start, width) = geometry.sectors[i]
            let remaining = Double(entry.remainingBps) / 10_000
            // A selection dims every other sector so the chosen one reads at a glance.
            let dim = (selectedID != nil && selectedID != entry.id ? 0.3 : 1) * (entry.value.isHistorical ? 0.45 : 1)
            for k in 0..<rays {
                let a = start + (Double(k) + 0.5) / Double(rays) * width
                var length = max(2 * unit, remaining * span * QuotaSpectrumModel.jitter(sector: i, ray: k))
                var opacity = 0.25 + remaining * 0.7
                if entry.isExpiring, let time {
                    let f = 0.5 + 0.5 * sin(time * 2 * .pi / (0.8 + Double(k % 4) * 0.25) + Double(k) * 0.9 + Double(i))
                    length *= 0.6 + 0.4 * f
                    opacity = 0.55 + 0.45 * f
                }
                var path = Path()
                path.move(to: geometry.point(a, inner)); path.addLine(to: geometry.point(a, inner + length))
                gc.stroke(path, with: .color((entry.isExpiring ? palette.signal : palette.ink).opacity((entry.isExpiring ? opacity : min(opacity, 0.95)) * dim)),
                          style: StrokeStyle(lineWidth: entry.id == selectedID ? 2 : entry.isExpiring ? 1.6 : 1.2, lineCap: .round))
            }
            if entry.isExpiring { labels.append((start + width * 0.43, entry)) }
        }

        for (a, entry) in labels {
            // Countdown only: the side margin cannot fit a name; tapping the sector names it.
            let text = gc.resolve(Text(entry.countdown?.text ?? "").font(.system(size: 10)).foregroundStyle(palette.signal))
            let box = text.measure(in: size)
            let anchor = geometry.point(a, inner + span + 14 * unit)
            let x = min(max(anchor.x + (cos(a) > 0.2 ? box.width / 2 : cos(a) < -0.2 ? -box.width / 2 : 0), box.width / 2), size.width - box.width / 2)
            let y = min(max(anchor.y, box.height / 2), size.height - box.height / 2)
            gc.draw(text, at: CGPoint(x: x, y: y))
        }
    }
}
