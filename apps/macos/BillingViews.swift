import SwiftUI
import QuotaCore
import QuotaPhone
import QuotaDesign

@MainActor
struct BillingOverview: View {
    let values: [QuotaPresentation]
    @ObservedObject var monitor: BillingMonitor
    var fixtureMode = false
    @State private var category = QuotaCategory.all
    @State private var search = ""
    var onSelect: (QuotaPresentation) -> Void
    @Environment(\.colorScheme) private var scheme

    private var filtered: [QuotaPresentation] {
        values.filter {
            category.includes($0.window) && (search.isEmpty ||
                ($0.window.accountAlias + " " + ProviderCatalog.identity(for: $0.window.providerId).displayName).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    categorySegments.fixedSize()
                    Spacer(minLength: 12)
                    searchField.frame(width: 190)
                }
                HStack(spacing: 12) {
                    categoryPicker.pickerStyle(.menu).frame(width: 160)
                    Spacer(minLength: 12)
                    searchField.frame(maxWidth: 220)
                }
            }.fixedSize(horizontal: false, vertical: true)
            let alerts = values.enumerated().filter { monitor.severity(for: $0.element.window) != .normal }
                .sorted {
                    let left = monitor.severity(for: $0.element.window), right = monitor.severity(for: $1.element.window)
                    return left == right ? $0.offset < $1.offset : left > right
                }.map(\.element)
            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("billing.attention"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(alerts.prefix(2)), id: \.window.id) { value in
                        Button { select(value) } label: {
                            HStack {
                                Text(ProviderCatalog.identity(for: value.window.providerId).displayName + " · " + value.window.accountAlias)
                                Spacer()
                                Text(value.number).monospacedDigit()
                                Image(systemName: "chevron.right")
                            }
                        }.buttonStyle(.plain)
                    }
                    if alerts.count > 2 { Text(L("billing.moreAlerts", alerts.count - 2)).font(.caption) }
                }.padding(16).foregroundStyle(PaperInk(scheme).warning).studioSurface(radius: 14)
            }
            if filtered.isEmpty {
                Text(L("billing.noMatches")).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ViewThatFits(in: .horizontal) {
                metricTable(compact: false).frame(minWidth: 900)
                metricTable(compact: true)
            }
        }
    }

    private func metricTable(compact: Bool) -> some View {
        VStack(spacing: 12) {
            if !compact {
                HStack(spacing: 12) {
                    Text(L("compact.metric")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("compact.reading")).frame(width: 90, alignment: .trailing)
                    Text(L("compact.remaining")).frame(width: 80)
                    Text(L("compact.resetStatus")).frame(width: 112, alignment: .trailing)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
            }
            ForEach(QuotaAccountGroup.grouped(filtered)) { group in
                Group {
                    if compact {
                        VStack(alignment: .leading, spacing: 0) {
                            accountHeading(group)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(PaperInk(scheme).track.opacity(0.35))
                            metricRows(group, compact: true)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            accountHeading(group).frame(width: 156, alignment: .leading)
                            metricRows(group, compact: false).frame(maxWidth: .infinity)
                        }
                    }
                }
                .studioSurface(radius: 11)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(PaperInk(scheme).divider, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func accountHeading(_ group: QuotaAccountGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderMark(providerID: group.providerID, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(ProviderCatalog.identity(for: group.providerID).displayName)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(group.accountAlias).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
    }

    private func metricRows(_ group: QuotaAccountGroup, compact: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(group.values, id: \.window.id) { value in
                Button { select(value) } label: {
                    BillingMetricRow(value: value, severity: monitor.severity(for: value.window),
                                     rule: monitor.rules[value.window.id], showsAccount: false, compact: compact)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("billing-metric-" + value.window.id)
                if value.window.id != group.values.last?.window.id { StudioDivider().padding(.horizontal, 14) }
            }
        }
        .accessibilityIdentifier("billing-account-" + group.id)
    }
    private var categorySegments: some View {
        HStack(spacing: 2) {
            ForEach(QuotaCategory.allCases) { item in
                Button { category = item } label: {
                    Text(item.title).font(.system(size: 12, weight: category == item ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(category == item ? PaperInk(scheme).elevated : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
            }
        }.padding(2).background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L("billing.filter"))
    }
    private var categoryPicker: some View {
        Picker(L("billing.filter"), selection: $category) {
            ForEach(QuotaCategory.allCases) { Text($0.title).tag($0) }
        }.labelsHidden()
    }
    private var searchField: some View {
        TextField(L("billing.search"), text: $search).textFieldStyle(.roundedBorder)
    }
    private func select(_ value: QuotaPresentation) { onSelect(value) }

}

/// Pack each account into the shortest column using its measured height, so a
/// five-metric account never reserves empty space below its one-metric neighbor.
struct BillingCardLayout: Layout {
    private static let spacing: CGFloat = 16
    private static let minimumWidth: CGFloat = 300

    static func columnCount(width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumWidth + spacing)))
    }

    static func columnWidth(width: CGFloat) -> CGFloat {
        let count = columnCount(width: width)
        return max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
    }

    static func frames(width: CGFloat, heights: [CGFloat]) -> [CGRect] {
        let cardWidth = columnWidth(width: width)
        var bottoms = Array(repeating: CGFloat.zero, count: columnCount(width: width))
        return heights.map { height in
            // Keep ties left-to-right and preserve source order for accessibility.
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
            let frame = CGRect(x: CGFloat(column) * (cardWidth + spacing),
                               y: bottoms[column], width: cardWidth, height: height)
            bottoms[column] = frame.maxY + spacing
            return frame
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let proposal = ProposedViewSize(width: Self.columnWidth(width: width), height: nil)
        return Self.frames(width: width, heights: subviews.map { $0.sizeThatFits(proposal).height })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? Self.minimumWidth
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : Self.minimumWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

@MainActor
struct BillingRuleEditor: View {
    let window: QuotaWindow
    @ObservedObject var monitor: BillingMonitor
    @State private var warning = ""
    @State private var critical = ""
    @State private var enabled = true
    @State private var saved = false
    private var template: BillingRule? { monitor.rules[window.id] ?? BillingRule.suggested(for: window) }
    private var draft: BillingRule? {
        guard let template else { return nil }
        return BillingRule(windowID: window.id, kind: template.kind, currency: template.currency,
            warning: warning, critical: critical, enabled: enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("billing.ruleTitle")).font(.system(size: 13, weight: .semibold))
            if let template {
                Text(L(template.kind == .budget ? "billing.budgetHelp" : "billing.lowHelp")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("billing.enabled"), isOn: $enabled)
                LabeledContent(L("billing.warningThreshold")) {
                    TextField("", text: $warning).textFieldStyle(.roundedBorder).frame(width: 84)
                        .accessibilityLabel(L("billing.warningThreshold"))
                    Text(template.currency ?? "%")
                }
                LabeledContent(L(template.kind == .budget ? "billing.budget" : "billing.criticalThreshold")) {
                    TextField("", text: $critical).textFieldStyle(.roundedBorder).frame(width: 84)
                        .accessibilityLabel(L("billing.criticalThreshold"))
                    Text(template.currency ?? "%")
                }
                if draft?.isValid != true { Text(L("billing.invalidRule")).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(L("billing.save")) {
                        if let draft { saved = monitor.save(draft) }
                    }.disabled(draft?.isValid != true)
                    if monitor.rules[window.id] != nil {
                        Button(L("billing.remove"), role: .destructive) { monitor.remove(window.id); saved = false }
                    }
                    if saved { Image(systemName: "checkmark").accessibilityLabel(L("billing.saved")) }
                }
                Text(L("billing.ruleFootnote")).font(.caption).foregroundStyle(.secondary)
            } else { Text(L("billing.ruleUnsupported")).font(.caption).foregroundStyle(.secondary) }
            if !monitor.message.isEmpty { Text(monitor.message).font(.caption).foregroundStyle(.red) }
        }
        .task(id: window.id) {
            warning = template?.warning ?? ""; critical = template?.critical ?? ""
            enabled = template?.enabled ?? true; saved = false
        }
        .onChange(of: warning) { _, _ in saved = false }
        .onChange(of: critical) { _, _ in saved = false }
    }
}

@MainActor
struct BillingAlertsView: View {
    let values: [QuotaPresentation]
    @ObservedObject var monitor: BillingMonitor
    let resetReminders: ResetReminderCoordinator
    let fixtureMode: Bool
    @State private var selectedID: String?
    private var orderedRules: [BillingRule] {
        let windows = Dictionary(values.map { ($0.window.id, $0.window) }, uniquingKeysWith: { first, _ in first })
        return monitor.rules.values.sorted { left, right in
            let a = windows[left.windowID].map { monitor.severity(for: $0) } ?? .normal
            let b = windows[right.windowID].map { monitor.severity(for: $0) } ?? .normal
            if a != b { return a > b }
            if (windows[left.windowID] != nil) != (windows[right.windowID] != nil) { return windows[left.windowID] != nil }
            return left.id < right.id
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("billing.alertsTitle")).studioType(.title)
                Text(L("billing.localMonitoring")).foregroundStyle(.secondary)
                ResetReminderSettingsView(coordinator: resetReminders).disabled(fixtureMode)
                Divider()
                Toggle(L("billing.macNotifications"), isOn: Binding(get: { monitor.notificationsEnabled }, set: { enabled in
                    Task { await monitor.setNotifications(enabled) }
                }))
                Toggle(L("billing.phoneAlerts"), isOn: Binding(get: { monitor.phoneAlertsEnabled }, set: { enabled in
                    Task { await monitor.setPhoneAlerts(enabled) }
                })).disabled(monitor.phoneRelay == nil)
                if monitor.phoneRelay == nil {
                    Text(L("billing.phone.unavailable")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("billing.phone.hint")).font(.caption).foregroundStyle(.secondary)
                }
                if !monitor.message.isEmpty { Text(monitor.message).foregroundStyle(.red) }
                if monitor.rules.isEmpty { Text(L("billing.noRules")).padding(.vertical, 24) }
                VStack(spacing: 0) {
                    HStack {
                        Text(L("compact.rules"))
                        Spacer()
                        Text(L("billing.warningThreshold")).frame(width: 90)
                        Text(L("billing.criticalThreshold")).frame(width: 90)
                        Text(L("billing.enabled")).frame(width: 52)
                    }.font(.caption).foregroundStyle(.secondary).padding(12)
                    ForEach(orderedRules) { rule in
                        StudioDivider()
                        if let value = values.first(where: { $0.window.id == rule.windowID }) {
                            HStack(spacing: 12) {
                                Button { selectedID = selectedID == rule.id ? nil : rule.id } label: {
                                    HStack(spacing: 8) {
                                        ProviderMark(providerID: value.window.providerId, size: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(value.window.accountAlias + " · " + value.window.shortDisplayName)
                                            Text(value.number).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityHint(L("billing.details"))
                                Text(rule.warning + " " + (rule.currency ?? "%")).monospacedDigit().frame(width: 90)
                                Text(rule.critical + " " + (rule.currency ?? "%")).monospacedDigit().frame(width: 90)
                                Toggle(L("billing.enabled"), isOn: Binding(get: { rule.enabled }, set: { enabled in
                                    if monitor.save(BillingRule(windowID: rule.windowID, kind: rule.kind, currency: rule.currency,
                                                               warning: rule.warning, critical: rule.critical, enabled: enabled)) {
                                        selectedID = nil
                                    }
                                })).labelsHidden().toggleStyle(.switch).frame(width: 52)
                                    .accessibilityLabel(value.window.accountAlias + " · " + value.window.shortDisplayName + " · " + L("billing.enabled"))
                            }.padding(12)
                            if selectedID == rule.id {
                                BillingRuleEditor(window: value.window, monitor: monitor).padding(16)
                            }
                        } else {
                            HStack {
                                Text(L("billing.missingMetric"))
                                Spacer()
                                Button(L("billing.remove"), role: .destructive) { monitor.remove(rule.id) }
                            }.padding(12)
                        }
                    }
                }.studioSurface(radius: 11)

            }.padding(24)
        }
    }
}
