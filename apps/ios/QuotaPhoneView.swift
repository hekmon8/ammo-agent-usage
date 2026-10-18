import SwiftUI
import QuotaCore
import QuotaDesign

/// A retained cache is never presented as a newly verified foreground reading.
/// This state is deliberately value-only so host transitions stay testable without
/// a Provider or transport fixture.
public enum PhoneRefreshFreshness: Sendable, Equatable {
    case verified, retainedPendingRefresh, retainedAfterFailure

    public var isOffline: Bool {
        self != .verified
    }

    public mutating func markCachedSnapshotLoaded() {
        self = .retainedPendingRefresh
    }

    public mutating func markRefreshSucceeded() {
        self = .verified
    }

    public mutating func markRefreshFailed() {
        self = .retainedAfterFailure
    }
}

/// Provider cards retain separate accounts, measurements and reset schedules.
/// The host owns verified data and refresh lifecycle.
public struct QuotaPhoneView: View {
    let values: [QuotaPresentation]
    let now: Date
    let pairing: PairingPresentation?
    let remoteUpdatesConfigured: Bool
    @State private var category = QuotaCategory.all
    @State private var detailsWindowID: String?

    public init(values: [QuotaPresentation] = [], now: Date = Date(), pairing: PairingPresentation? = nil, remoteUpdatesConfigured: Bool = false) {
        self.values = values
        self.now = now
        self.pairing = pairing
        self.remoteUpdatesConfigured = remoteUpdatesConfigured
    }

    public var body: some View {
        Group {
            let groups = QuotaProviderGroup.groups(values)
            if groups.isEmpty {
                PhoneEmptyState(pairing: pairing)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    let spectrum = QuotaSpectrumModel(values, now: now)
                    if !spectrum.isEmpty {
                        QuotaSpectrumView(model: spectrum) { detailsWindowID = $0 }
                    }
                    HStack {
                        Text(L("design.itemCount", values.count)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker(L("billing.filter"), selection: $category) {
                            ForEach(QuotaCategory.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu)
                    }
                    let filtered = values.filter { category.includes($0.window) }
                    if filtered.isEmpty {
                        Text(L("billing.noMatches")).foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(QuotaProviderGroup.groups(filtered)) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            PhoneProviderGroupHeader(providerID: group.providerID)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            StudioDivider()
                            let accounts = QuotaAccountGroup.grouped(group.values)
                            ForEach(accounts) { account in
                                if accounts.count > 1 {
                                    Text(account.accountAlias).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                                }
                                ForEach(account.values, id: \.window.id) { value in
                                    Button { detailsWindowID = value.window.id } label: {
                                        BillingMetricRow(value: value, showsAccount: false, compact: true)
                                    }.buttonStyle(.plain)
                                        .accessibilityIdentifier("phone-metric-" + value.window.id)
                                    if value.window.id != account.values.last?.window.id { StudioDivider().padding(.horizontal, 14) }
                                }
                                if account.id != accounts.last?.id { StudioDivider() }
                            }
                        }.studioSurface(radius: 16)
                            .accessibilityIdentifier("phone-provider-" + group.providerID)
                    }
                }
                .sheet(isPresented: Binding(get: { detailsWindowID != nil }, set: { if !$0 { detailsWindowID = nil } })) {
                    if let value = values.first(where: { $0.window.id == detailsWindowID }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack {
                                    Text(L("billing.details")).font(.headline)
                                    Spacer()
                                    Button(L("settings.connections.close")) { detailsWindowID = nil }
                                }
                                BillingMetricDetails(value: value)
                                Text(L("billing.phoneRules")).font(.caption).foregroundStyle(.secondary)
                            }.padding(24)
                        }.presentationDetents([.medium, .large])
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

public enum PhoneSection: Hashable, CaseIterable {
    case overview, usage, settings
}

/// Shared native navigation surface, with full accessible labels for icon-only tabs.
public struct PhoneSectionBar: View {
    let selected: PhoneSection
    let onSelect: (PhoneSection) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(selected: PhoneSection, onSelect: @escaping (PhoneSection) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 6) {
            sectionButton(L("phone.section.overview"), symbol: "gauge.with.dots.needle.33percent", target: .overview)
            sectionButton(L("tokenUsage.title"), symbol: "chart.bar.fill", target: .usage)
            sectionButton(L("phone.section.settings"), symbol: "gearshape", target: .settings)
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(PaperInk(scheme).divider, lineWidth: 0.5))
        .padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 6)
    }

    private func sectionButton(_ title: String, symbol: String, target: PhoneSection) -> some View {
        Button { onSelect(target) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                if selected == target {
                    Text(title).font(.subheadline.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected == target ? PaperInk(scheme).accent.opacity(0.12) : Color.clear, in: Capsule())
            .contentShape(Capsule())
            .foregroundStyle(selected == target ? PaperInk(scheme).accent : PaperInk(scheme).muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected == target ? .isSelected : [])
    }
}

/// Provider section header shared by the phone surfaces: brand mark plus the
/// provider name, leading a block of that provider's windows.
public struct PhoneProviderGroupHeader: View {
    let providerID: String
    @Environment(\.colorScheme) private var scheme

    public init(providerID: String) { self.providerID = providerID }

    public var body: some View {
        let identity = ProviderCatalog.identity(for: providerID)
        HStack(spacing: 8) {
            ProviderMark(providerID: providerID, size: 32, glyphFraction: 0.66)
            Text(identity.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PaperInk(scheme).ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.displayName)
    }
}

/// One provider block: the provider header, its windows as a two-column orbit
/// grid, and — while an orbit is tapped open — that window's details card.
/// The alias repeats under each orbit only when the provider spans accounts.
private struct PhoneProviderSection: View {
    let group: QuotaProviderGroup
    @Binding var detailsWindowID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsAccount = Set(group.values.map(\.window.accountId)).count > 1
        VStack(alignment: .leading, spacing: 14) {
            PhoneProviderGroupHeader(providerID: group.providerID)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                ForEach(group.values, id: \.window.id) { value in
                    PhoneMiniOrbit(value: value, showsAccount: showsAccount,
                                   showsDetails: Binding(
                                       get: { detailsWindowID == value.window.id },
                                       set: { expanded in
                                           withAnimation(reduceMotion ? nil : QuotaMotion.spring) {
                                               detailsWindowID = expanded ? value.window.id : nil
                                           }
                                       }))
                }
            }
            if let details = group.values.first(where: { $0.window.id == detailsWindowID }) {
                PhoneOrbitDetails(value: details)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A percentage drops its sign inside the orbit; the dots already read as a
/// ratio. Amounts, "unlimited" and "—" stay verbatim.
private func orbitNumber(_ value: QuotaPresentation) -> String {
    value.visibleBps == nil ? value.number : value.number.replacingOccurrences(of: "%", with: "")
}

/// The orbit carries the low tone; the number stays ink unless the reading is
/// spent, historical or unavailable.
private func orbitNumberColor(_ value: QuotaPresentation, _ scheme: ColorScheme) -> Color {
    let visual = QuotaVisualState(value)
    return [.normal, .low].contains(visual) ? PaperInk(scheme).ink : visual.color(for: scheme)
}

private struct PhoneMiniOrbit: View {
    let value: QuotaPresentation
    let showsAccount: Bool
    @Binding var showsDetails: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PaperInk(scheme)
        Button { showsDetails.toggle() } label: {
            VStack(spacing: 10) {
                ZStack {
                    QuotaDotOrbit(value: value, dots: 36, scheme: scheme)
                    Text(orbitNumber(value))
                        .font(.system(size: value.visibleBps == nil ? 17 : 32, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(orbitNumberColor(value, scheme))
                        .padding(.horizontal, 22)
                }
                .frame(width: 116, height: 116)
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if value.isHistorical {
                            Image(systemName: "clock").font(.caption2).foregroundStyle(palette.muted)
                        }
                        Text(value.window.shortDisplayName)
                            .font(.footnote)
                            .foregroundStyle(palette.ink)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    if showsAccount {
                        Text(value.window.accountAlias)
                            .font(.caption2).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("phone.orbit.detailsHint"))
        .accessibilityAddTraits(showsDetails ? .isSelected : [])
    }
}

/// The expanded card behind an orbit tap: account and reading on top, then
/// freshness, observation and reset times, and the trend when a ratio exists.
private struct PhoneOrbitDetails: View {
    let value: QuotaPresentation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PaperInk(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.window.accountAlias).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(value.valueHeading).font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(value.number).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 6) {
                FreshnessBadge(value)
                if let date = value.window.observedAt.flatMap(QuotaRules.date) {
                    Text(L("phone.quota.collectedAt", date.formatted(date: .abbreviated, time: .shortened)))
                }
                if let date = value.window.window.resetsAt.flatMap(QuotaRules.date) {
                    Text(L("phone.quota.resetsAt", date.formatted(date: .abbreviated, time: .shortened)))
                }
            }
            .font(.caption).foregroundStyle(palette.muted)
            if value.visibleBps != nil {
                QuotaTrend(value, chartHeight: 72).foregroundStyle(palette.ink)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.divider, lineWidth: 0.5))
    }
}

public struct PhoneAppearanceSettings: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(QuotaAppearanceKeys.displayStyle) private var storedStyle = QuotaDisplayStyle.calibrated.rawValue
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("phone.appearance.title"), systemImage: "paintpalette").font(.headline)
            Picker(L("phone.appearance.displayStyle"), selection: $storedStyle) {
                ForEach(QuotaDisplayStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
            }.pickerStyle(.segmented)
            Text(styleDescription(QuotaDisplayStyle(storedValue: storedStyle)))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("phone.appearance.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func styleDescription(_ style: QuotaDisplayStyle) -> String {
        switch style {
        case .contour: L("phone.appearance.style.contour")
        case .calibrated: L("phone.appearance.style.calibrated")
        case .soft: L("phone.appearance.style.soft")
        case .ring: L("phone.appearance.style.ring")
        }
    }
}

public struct PairingPresentation: Sendable, Equatable {
    public let workerHost: String
    public let sourceMacName: String
    public let privacySummary: String

    public init(workerHost: String, sourceMacName: String, privacySummary: String) {
        self.workerHost = workerHost
        self.sourceMacName = sourceMacName
        self.privacySummary = privacySummary
    }
}

private struct PhoneEmptyState: View {
    let pairing: PairingPresentation?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("phone.empty.title")).font(.title2)
            Text(L("phone.empty.noRecords")).font(.headline)
            if let pairing {
                Text(L("phone.empty.sourceMac", pairing.sourceMacName))
                Text(L("phone.empty.syncURL", pairing.workerHost))
                Text(pairing.privacySummary)
            } else {
                Text(L("phone.empty.instructions"))
            }
            Text(L("phone.empty.privacy"))
                .font(.caption).foregroundStyle(PaperInk(scheme).muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PaperInk(scheme).divider, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

public struct PhoneIslandStylePicker: View {
    @Binding var style: String
    let values: [QuotaPresentation]
    @Environment(\.colorScheme) private var scheme

    public init(style: Binding<String>, values: [QuotaPresentation]) {
        _style = style; self.values = values
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("phone.island.style")).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(ActivityCompactStyle.allCases) { option in
                    Button { style = option.rawValue } label: {
                        VStack(spacing: 10) {
                            ActivityQuotaGauge(number: values.first?.number ?? "—", remainingBps: values.first?.visibleBps,
                                               color: values.first.map { QuotaVisualState($0).color(for: .dark) } ?? .gray, style: option)
                                .padding(10).frame(maxWidth: .infinity)
                                .background(Color.black, in: Capsule())
                            Text(option.title).font(.caption.weight(.medium))
                            Image(systemName: style == option.rawValue ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(style == option.rawValue ? PaperInk(scheme).accent : PaperInk(scheme).muted)
                        }
                        .padding(.vertical, 12).padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .background(PaperInk(scheme).canvas, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(style == option.rawValue ? PaperInk(scheme).accent : Color.clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(style == option.rawValue ? .isSelected : [])
                }
            }
            if values.count > 1 {
                HStack {
                    ForEach(values, id: \.window.id) { value in
                        HStack(spacing: 8) {
                            ActivityQuotaGauge(number: value.number, remainingBps: value.visibleBps,
                                               color: QuotaVisualState(value).color(for: .dark), style: ActivityCompactStyle(storedValue: style))
                            Text(value.window.shortDisplayName).font(.caption2).foregroundStyle(.white).lineLimit(1)
                        }
                        .padding(10).background(.black, in: Capsule())
                    }
                }
            }
            Text(L("phone.island.previewFooter"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One inline quota-choice row. The phone UI selects windows in place; there are
/// deliberately no tap-to-popup menus on this screen. An optional priority index
/// renders inside the selection circle for ordered multi-select lists.
public struct PhoneQuotaOptionRow: View {
    let value: QuotaPresentation
    let selected: Bool
    var badgeText: String?
    var priorityIndex: Int?
    var disabled: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    public init(value: QuotaPresentation, selected: Bool, badgeText: String? = nil, priorityIndex: Int? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.value = value
        self.selected = selected
        self.badgeText = badgeText
        self.priorityIndex = priorityIndex
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        let palette = PaperInk(scheme)
        Button {
            guard !disabled else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                ProviderMark(providerID: value.window.providerId, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.window.shortDisplayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(ProviderCatalog.identity(for: value.window.providerId).displayName + " · " + value.window.accountAlias)
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(palette.track, in: Capsule())
                } else {
                    Text(value.number)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                }
                if selected, let priorityIndex {
                    Text("\(priorityIndex)")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(palette.accent, in: Circle())
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(selected ? palette.accent : palette.track)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? palette.accent.opacity(0.08) : palette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? palette.accent : palette.divider, lineWidth: selected ? 1.2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(disabled && !selected ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
