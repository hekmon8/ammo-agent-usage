import SwiftUI
import QuotaCore

/// Presentation-only formatting; the collector and core own counting semantics.
public enum TokenUsageText {
    public static func agent(_ agent: TokenUsageAgent) -> String {
        switch agent { case .claudeCode: "Claude Code"; case .codex: "Codex" }
    }

    public static func provider(_ agent: TokenUsageAgent) -> String {
        switch agent { case .claudeCode: "claude-code"; case .codex: "codex" }
    }

    public static func diagnostic(_ code: String?) -> String? {
        switch code {
        case "logs_unavailable": L("tokenUsage.diagnostic.logsUnavailable")
        case "no_usage_records": L("tokenUsage.diagnostic.noRecords")
        case "incomplete_scan": L("tokenUsage.diagnostic.incomplete")
        default: nil // Never render arbitrary diagnostics or local paths.
        }
    }

    public static func period(_ period: TokenUsagePeriod) -> String {
        switch period {
        case .day: L("tokenUsage.period.day")
        case .week: L("tokenUsage.period.week")
        case .month: L("tokenUsage.period.month")
        case .last7Days: L("tokenUsage.period.last7Days")
        }
    }

    public static func number(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let magnitude = Double(value)
        let locale = Locale(identifier: L10n.effectiveLanguageCode)
        if magnitude >= 1_000_000_000 { return String(format: "%.2fB", locale: locale, magnitude / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.2fM", locale: locale, magnitude / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.1fK", locale: locale, magnitude / 1_000) }
        return value.formatted(.number.locale(locale))
    }

    public static func date(_ date: Date, timeZone: TimeZone, time: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.effectiveLanguageCode)
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = time ? .short : .none
        return formatter.string(from: date)
    }

    public static func range(_ summary: TokenUsageSummary, timeZone: TimeZone) -> String {
        range(start: summary.start, end: summary.end, timeZone: timeZone)
    }

    public static func range(start: Date, end: Date, timeZone: TimeZone) -> String {
        let last = end.addingTimeInterval(-1)
        if calendar(timeZone).isDate(start, equalTo: last, toGranularity: .day) {
            return date(start, timeZone: timeZone)
        }
        return date(start, timeZone: timeZone) + " – " + date(last, timeZone: timeZone)
    }

    public static func status(_ source: TokenUsageSource?) -> String {
        guard let source else { return L("tokenUsage.source.unavailable") }
        switch source.status {
        case .available: return L("tokenUsage.source.available")
        case .partial: return L("tokenUsage.source.partial")
        case .unavailable: return L("tokenUsage.source.unavailable")
        case .disabled: return L("tokenUsage.source.disabled")
        }
    }

    public static func coverageKey(_ sources: [TokenUsageSource]) -> String {
        if sources.contains(where: { $0.status == .partial }) { return "tokenUsage.coverage.partial" }
        if sources.contains(where: { $0.status == .available }) { return "tokenUsage.coverage.readable" }
        if !sources.isEmpty && sources.allSatisfy({ $0.status == .disabled }) { return "tokenUsage.source.disabled" }
        return "tokenUsage.source.unavailable"
    }

    public static func agentValue(_ agent: TokenUsageAgent, summary: TokenUsageSummary) -> String {
        guard let counts = summary.byAgent[agent] else { return number(nil) }
        if !summary.daily.contains(where: { $0.agent == agent }) { return L("tokenUsage.noRecordedEvents") }
        return number(counts.total)
    }

    /// A readable source with no bucket in this period is not a measured zero.
    public static func hasRecords(_ agent: TokenUsageAgent, summary: TokenUsageSummary) -> Bool {
        summary.daily.contains { $0.agent == agent }
    }

    public static func periodStatus(_ agent: TokenUsageAgent, source: TokenUsageSource?, summary: TokenUsageSummary) -> String {
        guard summary.byAgent[agent] != nil else { return status(source) }
        if !hasRecords(agent, summary: summary) { return L("tokenUsage.noRecordedEvents") }
        return L(source?.status == .partial ? "tokenUsage.source.partial" : "tokenUsage.coverage.readable")
    }

    public static func receiptScope(stale: Bool) -> String {
        let base = L("tokenUsage.receipt.scope")
        let qualifier = stale ? L("tokenUsage.receipt.cached") : nil
        return qualifier.map { base + " · " + $0 } ?? base
    }

    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public static func moved(_ anchor: Date, period: TokenUsagePeriod, offset: Int, timeZone: TimeZone) -> Date {
        let calendar = calendar(timeZone)
        let component: Calendar.Component = period == .month ? .month : .day
        let amount = (period == .week || period == .last7Days) ? offset * 7 : offset
        return calendar.date(byAdding: component, value: amount, to: anchor) ?? anchor
    }
}

/// Week means the natural Monday–Sunday week. Rolling seven days is a separate choice.
public struct TokenUsagePeriodPicker: View {
    @Binding var period: TokenUsagePeriod
    @Binding var anchor: Date
    let timeZone: TimeZone
    let range: String

    public init(period: Binding<TokenUsagePeriod>, anchor: Binding<Date>, timeZone: TimeZone, range: String) {
        _period = period; _anchor = anchor; self.timeZone = timeZone; self.range = range
    }

    public var body: some View {
        VStack(spacing: 12) {
            Picker(L("tokenUsage.period.label"), selection: $period) {
                ForEach([TokenUsagePeriod.day, .week, .month, .last7Days], id: \.self) {
                    Text(TokenUsageText.period($0)).tag($0)
                }
            }.pickerStyle(.segmented)
            HStack(spacing: 12) {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .accessibilityLabel(L("tokenUsage.previous"))
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    Text(range).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                    Text(timeZone.identifier + (period == .week ? " · " + L("tokenUsage.mondayStart") : ""))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .accessibilityLabel(L("tokenUsage.next"))
                    .disabled(!canMoveForward)
            }.buttonStyle(.plain)
        }
    }

    private var canMoveForward: Bool {
        let next = TokenUsageText.moved(anchor, period: period, offset: 1, timeZone: timeZone)
        let calendar = TokenUsageText.calendar(timeZone)
        let component: Calendar.Component = period == .month ? .month : period == .week ? .weekOfYear : .day
        guard let nextStart = calendar.dateInterval(of: component, for: next)?.start else { return false }
        return nextStart <= Date()
    }

    private func move(_ offset: Int) {
        anchor = TokenUsageText.moved(anchor, period: period, offset: offset, timeZone: timeZone)
    }
}

public struct TokenUsageCoverageBadge: View {
    let key: String
    private var partial: Bool { key == "tokenUsage.coverage.partial" }
    private var readable: Bool { key == "tokenUsage.coverage.readable" }
    public init(partial: Bool) { key = partial ? "tokenUsage.coverage.partial" : "tokenUsage.coverage.readable" }
    public init(sources: [TokenUsageSource]) { key = TokenUsageText.coverageKey(sources) }
    public var body: some View {
        Text(L(key))
            .font(.caption.weight(.medium))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(partial ? Color.orange : readable ? Color(red: 0.32, green: 0.44, blue: 0.35) : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((partial ? Color.orange : readable ? Color.green : Color.gray).opacity(0.10), in: Capsule())
    }
}

public struct TokenUsageOverviewCard: View {
    let snapshot: TokenUsageSnapshot
    let summary: TokenUsageSummary
    let timeZone: TimeZone
    let stale: Bool
    @Environment(\.colorScheme) private var scheme

    public init(snapshot: TokenUsageSnapshot, summary: TokenUsageSummary, timeZone: TimeZone, stale: Bool = false) {
        self.snapshot = snapshot; self.summary = summary; self.timeZone = timeZone; self.stale = stale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("tokenUsage.recorded")).font(.headline)
                TokenUsageCoverageBadge(sources: snapshot.sources)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenUsageText.number(summary.daily.isEmpty ? nil : summary.total?.total))
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
                Text("Token").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("tokenUsage.scope.singleMac")).font(.caption).foregroundStyle(.secondary)
                if let date = QuotaRules.date(snapshot.capturedAt) {
                    Text(L("tokenUsage.asOf", TokenUsageText.date(date, timeZone: timeZone, time: true)))
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text(L("tokenUsage.freshness.unknown")).font(.caption).foregroundStyle(.secondary) }
                if stale { Label(L("tokenUsage.freshness.cached"), systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            }
            if summary.total == nil {
                Label(L("tokenUsage.noReadableRecords"), systemImage: "questionmark.circle").foregroundStyle(.secondary)
            } else if summary.daily.isEmpty {
                Label(L("tokenUsage.emptyRange"), systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                Text(L("tokenUsage.emptyRange.action")).font(.caption).foregroundStyle(.secondary)
            } else {
                TokenUsageDailyChart(buckets: summary.daily, start: summary.start, end: summary.end, timeZone: timeZone)
                    .frame(height: 145)
            }
            DisclosureGroup(L("tokenUsage.details")) {
                TokenUsageCategories(counts: summary.daily.isEmpty ? nil : summary.total).padding(.top, 12)
                Text(L("tokenUsage.categories.explanation")).font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline)
        }
        .padding(20)
        .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PaperInk(scheme).divider, lineWidth: 0.5))
    }
}

public struct TokenUsageCategories: View {
    let counts: TokenUsageCounts?
    let receipt: Bool
    public init(counts: TokenUsageCounts?, receipt: Bool = false) { self.counts = counts; self.receipt = receipt }
    private var rows: [(String, Int64?)] {
        [("tokenUsage.category.input", counts?.nonCachedInput), ("tokenUsage.category.cacheRead", counts?.cacheRead),
         ("tokenUsage.category.cacheWrite", counts?.cacheWrite), ("tokenUsage.category.output", counts?.output)]
    }
    public var body: some View {
        if receipt {
            VStack(spacing: 9) {
                ForEach(rows, id: \.0) { row in
                    HStack { Text(L(row.0)); Spacer(); Text(TokenUsageText.number(row.1)).monospacedDigit() }
                }
            }.font(.system(size: 16, design: .monospaced))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), alignment: .leading)], alignment: .leading, spacing: 16) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L(row.0)).font(.caption).foregroundStyle(.secondary)
                        Text(TokenUsageText.number(row.1)).font(.title3.weight(.semibold)).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
}

public struct TokenUsageDailyChart: View {
    let buckets: [TokenUsageBucket]
    let start: Date
    let end: Date
    let timeZone: TimeZone
    @Environment(\.colorScheme) private var scheme
    public init(buckets: [TokenUsageBucket], start: Date, end: Date, timeZone: TimeZone) {
        self.buckets = buckets; self.start = start; self.end = end; self.timeZone = timeZone
    }
    private struct Day: Identifiable {
        let id: String
        let label: String
        let total: Double
        let hasRecord: Bool
    }
    private var days: [Day] {
        let calendar = TokenUsageText.calendar(timeZone)
        let keyFormatter = DateFormatter()
        keyFormatter.calendar = calendar; keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.timeZone = timeZone; keyFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.locale = Locale(identifier: L10n.effectiveLanguageCode)
        labelFormatter.timeZone = timeZone
        labelFormatter.dateFormat = end.timeIntervalSince(start) > 8 * 86_400 ? "d" : "EEEEE"
        var result: [Day] = []
        var date = start
        while date < end && result.count < 32 {
            let key = keyFormatter.string(from: date)
            let values = buckets.filter { $0.day == key }
            result.append(Day(id: key, label: labelFormatter.string(from: date),
                              total: values.reduce(0) { $0 + Double($1.tokens.total) }, hasRecord: !values.isEmpty))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        return result
    }
    public var body: some View {
        let values = days
        let maximum = max(values.map(\.total).max() ?? 1, 1)
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: values.count > 14 ? 3 : 9) {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, day in
                    VStack(spacing: 7) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.hasRecord ? PaperInk(scheme).accent.opacity(0.68) : PaperInk(scheme).track)
                            .frame(height: day.hasRecord ? max(3, (geometry.size.height - 23) * day.total / maximum) : 2)
                        Text(values.count > 14 && index % 5 != 0 && index != values.count - 1 ? "" : day.label)
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 14)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.id + ": " + (day.hasRecord ? TokenUsageText.number(Int64(day.total)) : L("tokenUsage.noRecordedEvents")))
                }
            }
        }
    }
}

public struct TokenUsageAgentList: View {
    let snapshot: TokenUsageSnapshot
    let summary: TokenUsageSummary
    @Binding var selected: TokenUsageAgent?
    @Environment(\.colorScheme) private var scheme
    public init(snapshot: TokenUsageSnapshot, summary: TokenUsageSummary, selected: Binding<TokenUsageAgent?>) {
        self.snapshot = snapshot; self.summary = summary; _selected = selected
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("tokenUsage.byAgent")).font(.headline).padding(16)
            ForEach([TokenUsageAgent.codex, .claudeCode], id: \.self) { agent in
                let source = snapshot.sources.first { $0.agent == agent }
                let counts = summary.byAgent[agent]
                Button { selected = agent } label: {
                    HStack(spacing: 12) {
                        ProviderMark(providerID: TokenUsageText.provider(agent), size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(TokenUsageText.agent(agent)).font(.subheadline.weight(.medium))
                            Text(TokenUsageText.periodStatus(agent, source: source, summary: summary)).font(.caption).foregroundStyle(.secondary)
                            if let date = source?.latestEventAt.flatMap(QuotaRules.date),
                               let zone = TimeZone(identifier: snapshot.timeZoneIdentifier) {
                                Text(L("tokenUsage.source.latest", TokenUsageText.date(date, timeZone: zone)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(TokenUsageText.hasRecords(agent, summary: summary) ? TokenUsageText.agentValue(agent, summary: summary) : "—")
                            .monospacedDigit().fontWeight(.semibold)
                        if TokenUsageText.hasRecords(agent, summary: summary), let total = summary.total?.total, total > 0, let count = counts?.total {
                            Text((Double(count) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                .font(.caption).foregroundStyle(.secondary).frame(minWidth: 42, alignment: .trailing)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(selected == agent ? PaperInk(scheme).accent.opacity(0.08) : Color.clear)
                if agent == .codex { Divider().padding(.horizontal, 16) }
            }

        }.studioSurface(radius: 14)
    }
}

public struct TokenUsageSourceDetails: View {
    let snapshot: TokenUsageSnapshot
    let summary: TokenUsageSummary
    let selected: TokenUsageAgent?
    public init(snapshot: TokenUsageSnapshot, summary: TokenUsageSummary, selected: TokenUsageAgent?) {
        self.snapshot = snapshot; self.summary = summary; self.selected = selected
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let selected {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ProviderMark(providerID: TokenUsageText.provider(selected), size: 32)
                        Text(TokenUsageText.agent(selected)).font(.headline)
                    }
                    Text(TokenUsageText.agentValue(selected, summary: summary)).font(.title.bold()).monospacedDigit()
                    TokenUsageCategories(counts: TokenUsageText.hasRecords(selected, summary: summary) ? summary.byAgent[selected] : nil)
                }.padding(18).studioSurface(radius: 14)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(L("tokenUsage.coverage.title")).font(.headline)
                ForEach([TokenUsageAgent.codex, .claudeCode], id: \.self) { agent in
                    let source = snapshot.sources.first { $0.agent == agent }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(TokenUsageText.agent(agent)).font(.subheadline)
                            Spacer()
                            Text(TokenUsageText.status(source)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let scanned = source?.scannedAt.flatMap(QuotaRules.date) {
                            Text(L("tokenUsage.source.scanned", TokenUsageText.date(scanned, timeZone: TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current, time: true)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let latest = source?.latestEventAt.flatMap(QuotaRules.date) {
                            Text(L("tokenUsage.source.latest", TokenUsageText.date(latest, timeZone: TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current, time: true)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let explanation = TokenUsageText.diagnostic(source?.diagnostic) {
                            Text(explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text(L("tokenUsage.coverage.explanation")).font(.caption).foregroundStyle(.secondary)
            }.padding(18).studioSurface(radius: 14)
        }
    }
}

/// Allowlisted receipt projection. No device ID, account, project, conversation,
/// log path or diagnostic text can enter the image or sharing payload.
public struct TokenUsageReceiptData {
    public let start, end: Date
    public let total: TokenUsageCounts?
    public let byAgent: [TokenUsageAgent: TokenUsageCounts]
    public let daily: [TokenUsageBucket]
    public let isPartial: Bool
    public let timeZone: TimeZone
    public let capturedAt: Date?
    public let period: TokenUsagePeriod
    public let stale: Bool
    public init(snapshot: TokenUsageSnapshot, summary: TokenUsageSummary, period: TokenUsagePeriod, stale: Bool = false) {
        self.start = summary.start; self.end = summary.end; self.total = summary.total
        self.byAgent = summary.byAgent; self.daily = summary.daily; self.isPartial = summary.isPartial
        self.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
        self.capturedAt = QuotaRules.date(snapshot.capturedAt); self.period = period; self.stale = stale
    }
}

/// Fixed 540-point receipt at 2x renders the same 1080 × 1960 PNG on both platforms.
public struct TokenUsageReceiptView: View {
    public static let width: CGFloat = 540
    public static let height: CGFloat = 980
    let data: TokenUsageReceiptData
    public init(data: TokenUsageReceiptData) { self.data = data }
    private var agents: [TokenUsageAgent] {
        [TokenUsageAgent.codex, .claudeCode].filter { data.byAgent[$0] != nil }
            .sorted { (data.byAgent[$0]?.total ?? 0) > (data.byAgent[$1]?.total ?? 0) }
    }
    private func hasRecords(_ agent: TokenUsageAgent) -> Bool { data.daily.contains { $0.agent == agent } }
    public var body: some View {
        VStack(spacing: 17) {
            VStack(spacing: 7) {
                Text("Ammo").font(.system(size: 54, weight: .bold, design: .serif))
                Text("TOKEN RECEIPT").font(.system(size: 16, design: .monospaced)).tracking(5)
                Text(L("tokenUsage.receipt.subtitle")).font(.system(size: 14)).tracking(3)
            }
            dash
            VStack(spacing: 7) {
                Text(TokenUsageText.range(start: data.start, end: data.end, timeZone: data.timeZone)).font(.system(size: 16, weight: .medium, design: .monospaced))
                Text(data.timeZone.identifier + " · " + TokenUsageText.period(data.period))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                HStack { Text("AGENT"); Spacer(); Text("TOKENS") }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Divider()
                ForEach(agents, id: \.self) { agent in
                    HStack(spacing: 10) {
                        ProviderBrandAsset(providerID: TokenUsageText.provider(agent)).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(TokenUsageText.agent(agent))
                            if !hasRecords(agent) {
                                Text(L("tokenUsage.noRecordedEvents")).font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(TokenUsageText.number(hasRecords(agent) ? data.byAgent[agent]?.total : nil)).monospacedDigit()
                    }.font(.system(size: 18, design: .monospaced))
                }
            }
            if let leader = agents.first, let value = data.byAgent[leader], value.total > 0 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("tokenUsage.receipt.topAgent")).font(.system(size: 12, design: .monospaced))
                        Text(TokenUsageText.agent(leader)).font(.system(size: 25, weight: .bold, design: .serif))
                    }
                    Spacer()
                    Text(TokenUsageText.number(value.total)).font(.system(size: 25, weight: .bold, design: .serif))
                }.padding(15).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(red: 0.51, green: 0.59, blue: 0.47), lineWidth: 2))
            }
            TokenUsageDailyChart(buckets: data.daily, start: data.start, end: data.end, timeZone: data.timeZone).frame(height: 118)
            dash
            HStack(alignment: .firstTextBaseline) {
                Text("TOTAL").font(.system(size: 16, design: .monospaced)).tracking(2)
                Spacer()
                Text(TokenUsageText.number(data.daily.isEmpty ? nil : data.total?.total)).font(.system(size: 58, weight: .bold, design: .serif)).minimumScaleFactor(0.65)
                Text("Token").font(.system(size: 13))
            }
            TokenUsageCategories(counts: data.daily.isEmpty ? nil : data.total, receipt: true)
            dash
            Text(TokenUsageText.receiptScope(stale: data.stale))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34).padding(.top, 35).padding(.bottom, 25)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.10))
        .background(Color(red: 0.97, green: 0.96, blue: 0.92))
        .clipShape(TokenReceiptPaper())
        .environment(\.colorScheme, .light)
        .environment(\.sizeCategory, .medium)
    }
    private var dash: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 0.8, dash: [5, 4])).frame(height: 1).foregroundStyle(.secondary)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: rect.width, y: 0)) } }
    }
}

private struct TokenReceiptPaper: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let teeth = 36
            let step = rect.width / CGFloat(teeth)
            path.move(to: CGPoint(x: 0, y: 7))
            for index in 0..<teeth {
                path.addLine(to: CGPoint(x: CGFloat(index) * step + step / 2, y: 0))
                path.addLine(to: CGPoint(x: CGFloat(index + 1) * step, y: 7))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - 7))
            for index in (0..<teeth).reversed() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step + step / 2, y: rect.height))
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: rect.height - 7))
            }
            path.closeSubpath()
        }
    }
}
