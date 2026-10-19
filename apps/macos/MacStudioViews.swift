import AppKit
import SwiftUI
import QuotaCore
import QuotaDesign

@MainActor
final class MacIslandViewState: ObservableObject {
    @Published var interaction = IslandInteractionState()
    @Published var cameraSize: CGSize?
    @Published var animationEnabled = true
    @Published var selectedAccountID: String?
}

/// Rebuilds its content when the in-app language changes, since localized
/// strings are captured at body evaluation.
struct LanguageSensitiveView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var revision = L10n.revision

    var body: some View {
        content
            .id(revision)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChange)) { _ in
                revision = L10n.revision
            }
    }
}

@MainActor
struct MacStudioIslandRoot: View {
    @ObservedObject var model: MacModel
    @ObservedObject var viewState: MacIslandViewState
    let fixture: [QuotaPresentation]?
    let onHover: (Bool) -> Void
    let onSelectIsland: () -> Void
    let onSelectWindow: (String) -> Void
    let onBack: () -> Void
    let onCollapse: () -> Void
    let onOpenDashboard: () -> Void
    let onSelectAccount: (String) -> Void

    var body: some View {
        LanguageSensitiveView {
            MacStudioIslandContent(
                model: model,
                fixture: fixture,
                state: viewState.interaction.presentation,
                cameraSize: viewState.cameraSize,
                // Native tracking owns hover across hosting-view resizes.
                onHover: { _ in },
                onSelectIsland: onSelectIsland,
                onSelectWindow: onSelectWindow,
                onBack: onBack,
                onCollapse: onCollapse,
                onOpenDashboard: onOpenDashboard,
                selectedAccountID: viewState.selectedAccountID,
                onSelectAccount: onSelectAccount,
                animationEnabled: viewState.animationEnabled
            )
        }
    }
}

@MainActor
struct MacStudioIslandContent: View {
    @ObservedObject var model: MacModel
    let fixture: [QuotaPresentation]?
    let state: IslandPresentationState
    let cameraSize: CGSize?
    let onHover: (Bool) -> Void
    let onSelectIsland: () -> Void
    let onSelectWindow: (String) -> Void
    let onBack: () -> Void
    let onCollapse: () -> Void
    var onOpenDashboard: () -> Void = {}
    var selectedAccountID: String?
    var onSelectAccount: (String) -> Void = { _ in }
    var animationEnabled = true
    var styleOverride: QuotaDisplayStyle?
    var edgeMotionOverride: Bool?
    var slotCountOverride: Int?

    @AppStorage(IslandPreferenceKeys.leftWindowID) private var leftWindowID = ""
    @AppStorage(IslandPreferenceKeys.rightWindowID) private var rightWindowID = ""
    @AppStorage(IslandPreferenceKeys.thirdWindowID) private var thirdWindowID = ""
    @AppStorage(IslandPreferenceKeys.visibleSlotCount) private var visibleSlotCount = 2
    @AppStorage("islandShowPeriod") private var showPeriod = true
    @AppStorage("islandShowReset") private var showReset = false
    @AppStorage(QuotaAppearanceKeys.displayStyle) private var storedDisplayStyle = QuotaDisplayStyle.calibrated.rawValue
    @AppStorage(QuotaAppearanceKeys.edgeMotion) private var storedEdgeMotion = true

    private var displayStyle: QuotaDisplayStyle {
        styleOverride ?? QuotaDisplayStyle(storedValue: storedDisplayStyle)
    }

    private var edgeMotion: Bool { edgeMotionOverride ?? storedEdgeMotion }
    private var slotCount: Int {
        IslandSummarySelection.normalizeVisibleCount(slotCountOverride ?? visibleSlotCount)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let values = fixture ?? model.islandWindows.map { QuotaPresentation(window: $0, now: context.date) }
            islandBody(values)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .foregroundStyle(.white)
                .background(Color.black)
                .clipShape(islandShape)
                .overlay {
                    QuotaEdgeBorder(
                        value: edgeValue(values),
                        style: displayStyle,
                        attachesToTop: cameraSize != nil,
                        animationEnabled: animationEnabled && edgeMotion
                    )
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onHover(perform: onHover)
                .onExitCommand(perform: onCollapse)
                .contextMenu {
                    Button(L("island.menu.openDashboard"), systemImage: "macwindow", action: onOpenDashboard)
                }
                .environment(\.colorScheme, .dark)
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cameraSize == nil ? 24 : 0,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 20,
            topTrailingRadius: cameraSize == nil ? 24 : 0,
            style: .continuous
        )
    }

    @ViewBuilder
    private func islandBody(_ values: [QuotaPresentation]) -> some View {
        switch state {
        case .collapsed:
            Button(action: onSelectIsland) {
                collapsedContent(values)
            }
            .buttonStyle(StudioPressButtonStyle())
            .help(L("island.help.expandOverview"))

        case .overview:
            overviewContent(values)

        case .detail(let windowID):
            if let value = values.first(where: { $0.window.id == windowID }) {
                detailContent(value)
            } else {
                islandMissingContent
            }
        }
    }

    private func collapsedContent(_ values: [QuotaPresentation]) -> some View {
        let summaries = IslandSummarySelection.select(
            values,
            leftID: leftWindowID,
            rightID: rightWindowID,
            thirdID: thirdWindowID,
            count: slotCount
        )
        return VStack(spacing: 1) {
            if summaries.items.count == 1, let slot = summaries.items.first {
                singleCollapsedSlot(slot)
            } else {
                HStack(spacing: 0) {
                    collapsedWing(summaries.items.first, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let cameraSize {
                        Color.clear.frame(width: cameraSize.width, height: cameraSize.height)
                    } else {
                        Spacer(minLength: 16)
                    }
                    collapsedWing(summaries.items.indices.contains(1) ? summaries.items[1] : nil, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if summaries.items.indices.contains(2) {
                thirdCollapsedSlot(summaries.items[2])
            }
        }
        .padding(.horizontal, 13)
    }

    @ViewBuilder
    private func collapsedWing(_ slot: IslandSummarySelection.Slot?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            if let value = slot?.value {
                HStack(spacing: 6) {
                    if alignment == .trailing { Spacer(minLength: 0) }
                    ProviderMark(providerID: value.window.providerId, size: 20)
                    statusIcon(value, size: 9)
                    Text(value.number)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(QuotaVisualState(value).color(for: .dark))
                    if alignment == .leading { Spacer(minLength: 0) }
                }
                if let subtitle = summarySubtitle(value) {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle")
                    Text("—").monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(L("island.state.unavailable"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot?.value.map(summaryAccessibilityLabel) ?? L("island.state.unavailable"))
    }

    private func singleCollapsedSlot(_ slot: IslandSummarySelection.Slot) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let value = slot.value {
                    ProviderMark(providerID: value.window.providerId, size: 20)
                    statusIcon(value, size: 9)
                    if let subtitle = summarySubtitle(value) {
                        Text(subtitle)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "questionmark.circle")
                    Text(L("island.state.unavailable")).font(.system(size: 9, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let cameraSize {
                Color.clear.frame(width: cameraSize.width, height: cameraSize.height)
            } else {
                Spacer(minLength: 16)
            }
            Text(slot.value?.number ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(slot.value.map { QuotaVisualState($0).color(for: .dark) } ?? .white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.value.map(summaryAccessibilityLabel) ?? L("island.state.unavailable"))
    }

    private func thirdCollapsedSlot(_ slot: IslandSummarySelection.Slot) -> some View {
        HStack(spacing: 7) {
            if let value = slot.value {
                ProviderMark(providerID: value.window.providerId, size: 18)
                statusIcon(value, size: 8)
                if let subtitle = summarySubtitle(value) {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(value.number)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(QuotaVisualState(value).color(for: .dark))
            } else {
                Image(systemName: "questionmark.circle")
                Text(L("island.state.unavailable")).font(.system(size: 9, weight: .medium))
                Spacer()
                Text("—").font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.value.map(summaryAccessibilityLabel) ?? L("island.state.unavailable"))
    }

    private func overviewContent(_ values: [QuotaPresentation]) -> some View {
        let groups = QuotaAccountGroup.grouped(values)
        let selection = IslandOverviewSelection.resolve(groups, selectedID: selectedAccountID)
        let selected = groups.first(where: { $0.id == selection.groupID })
        let selectedID = selected?.id
        let selectedValues = selected?.values ?? []
        let account = selected?.accountAlias

        return VStack(alignment: .leading, spacing: 10) {
            cameraClearance
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 8) {
                   ForEach(groups) { group in
                    Button {
                        onSelectAccount(group.id)
                    } label: {
                        HStack(spacing: 6) {
                            ProviderMark(providerID: group.providerID, size: 25, selected: selectedID == group.id)
                            if selectedID == group.id {
                                Text(ProviderCatalog.identity(for: group.providerID).shortName)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, selectedID == group.id ? 7 : 2)
                        .frame(height: 30)
                        .background(.white.opacity(selectedID == group.id ? 0.09 : 0),
                                    in: Capsule())
                    }
                    .buttonStyle(StudioPressButtonStyle())
                    .help("\(ProviderCatalog.identity(for: group.providerID).displayName) · \(group.accountAlias)")
                    .accessibilityLabel("\(ProviderCatalog.identity(for: group.providerID).displayName) · \(group.accountAlias)")
                   }
                  }
                }
                Spacer()
                openDashboardButton
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(StudioPressButtonStyle())
                .help(L("island.help.collapseIsland"))
            }

            if selectedValues.isEmpty {
                Button(action: onOpenDashboard) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                        Text(L("island.overview.connectCta"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(.vertical, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressButtonStyle())
                .accessibilityIdentifier("island-connect-service")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            } else {
                if let account {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                ScrollView(.vertical) {
                    if displayStyle == .contour {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(selectedValues, id: \.window.id) { value in
                                Button { onSelectWindow(value.window.id) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(value.window.shortDisplayName).font(.caption).lineLimit(1)
                                        Text(value.number).font(.title3.monospacedDigit())
                                        Text(value.status).font(.caption2).lineLimit(1)
                                        if value.visibleBps != nil { QuotaStyledProgress(value: value, style: .contour) }
                                    }
                                    .foregroundStyle(QuotaVisualState(value).color(for: .dark))
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
                                }.buttonStyle(StudioPressButtonStyle())
                            }
                        }
                    } else if displayStyle == .soft {
                        VStack(spacing: 8) {
                            ForEach(selectedValues, id: \.window.id) { value in
                                IslandLimitRow(value: value, style: .soft) { onSelectWindow(value.window.id) }
                            }
                        }
                    } else if displayStyle == .ring {
                        VStack(spacing: 8) {
                            ForEach(selectedValues, id: \.window.id) { value in
                                Button { onSelectWindow(value.window.id) } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(value.window.shortDisplayName).font(.caption).lineLimit(1)
                                            Text(value.number).font(.title3.monospacedDigit())
                                                .foregroundStyle(QuotaVisualState(value).color(for: .dark))
                                        }
                                        Spacer(minLength: 8)
                                        QuotaRingGauge(value: value, diameter: 34, showsNumber: false)
                                    }
                                    .padding(10)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }.buttonStyle(StudioPressButtonStyle())
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            ForEach(selectedValues, id: \.window.id) { value in
                                IslandLimitRow(value: value, style: .calibrated) { onSelectWindow(value.window.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 184)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectIsland)
    }

    private var openDashboardButton: some View {
        Button(action: onOpenDashboard) {
            Label(L("island.overview.dashboardButton"), systemImage: "macwindow")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(StudioPressButtonStyle())
        .help(L("island.overview.dashboardHelp"))
        .accessibilityLabel(L("island.menu.openDashboard"))
        .accessibilityIdentifier("island-open-dashboard")
    }

    private func detailContent(_ value: QuotaPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cameraClearance
            HStack(spacing: 9) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 27, height: 27)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(StudioPressButtonStyle())
                ProviderMark(providerID: value.window.providerId, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProviderCatalog.identity(for: value.window.providerId).displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(value.window.accountAlias)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                openDashboardButton
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .frame(width: 27, height: 27)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(StudioPressButtonStyle())
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.window.shortDisplayName)
                        .font(.headline)
                    ResetLabel(value)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text(value.number)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(QuotaVisualState(value).color(for: .dark))
            }
            if value.visibleBps != nil {
                if displayStyle == .ring {
                    HStack(alignment: .top, spacing: 12) {
                        QuotaRingGauge(value: value, diameter: 34, showsNumber: false)
                        QuotaTrend(value, chartHeight: 64, spacing: 5)
                            .font(.caption)
                            .foregroundStyle(ProviderCatalog.identity(for: value.window.providerId).tone.color(for: .dark))
                    }
                } else {
                    QuotaStyledProgress(value: value, style: displayStyle)
                    QuotaTrend(value, chartHeight: 64, spacing: 5)
                        .font(.caption)
                        .foregroundStyle(ProviderCatalog.identity(for: value.window.providerId).tone.color(for: .dark))
                }
            } else if value.window.unit == .money {
                Label(L("island.detail.noCap"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(value.status)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    private var cameraClearance: some View {
        Color.clear.frame(height: cameraSize.map { max(8, $0.height + 3) } ?? 8)
    }

    private func summarySubtitle(_ value: QuotaPresentation) -> String? {
        // With reset display enabled, an unused window has no countdown
        // yet — name that state instead of leaving an unexplained gap.
        let idleHint = showReset && !value.isHistorical && value.window.isIdleWindow
        let reset = value.state == .authRequired
            ? L("island.state.authRequired")
            : value.window.resetDescription() ?? (idleHint ? L("quota.reset.idleWindow") : nil)
        return IslandSummaryText.subtitle(
            period: value.window.shortDisplayName,
            reset: reset,
            showPeriod: showPeriod,
            // A paused authorization is a required action, not a countdown
            // preference, so its hint stays visible even when resets are hidden.
            showReset: showReset || value.state == .authRequired
        )
    }

    private func summaryAccessibilityLabel(_ value: QuotaPresentation) -> String {
        IslandSummaryText.accessibilityLabel(
            title: value.window.shortDisplayName,
            number: value.number,
            status: value.status
        )
    }

    private func statusIcon(_ value: QuotaPresentation, size: CGFloat) -> some View {
        let visual = QuotaVisualState(value)
        return Image(systemName: visual.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(visual.color(for: .dark))
            .accessibilityHidden(true)
    }

    private var islandMissingContent: some View {
        VStack(spacing: 10) {
            cameraClearance
            Image(systemName: "questionmark.circle").font(.title2)
            Text(L("island.detail.missingGeneric")).font(.caption)
            HStack {
                Button(L("island.action.back"), action: onBack)
                Button(L("island.overview.dashboardButton"), action: onOpenDashboard)
                Button(L("island.action.collapse"), action: onCollapse)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }

    private func edgeValue(_ values: [QuotaPresentation]) -> QuotaPresentation? {
        switch state {
        case .collapsed:
            return IslandSummarySelection.select(
                values,
                leftID: leftWindowID,
                rightID: rightWindowID,
                thirdID: thirdWindowID,
                count: slotCount
            ).items.compactMap(\.value).first
        case .overview:
            let groups = QuotaAccountGroup.grouped(values)
            return (groups.first { $0.id == selectedAccountID } ?? groups.first)?.values.first
        case .detail(let windowID):
            return values.first { $0.window.id == windowID }
        }
    }

}

private struct IslandLimitRow: View {
    let value: QuotaPresentation
    let style: QuotaDisplayStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                let visual = QuotaVisualState(value)
                Image(systemName: visual.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(visual.color(for: .dark))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.window.shortDisplayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if value.state == .authRequired {
                        Text(value.status)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        ResetLabel(value)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(value.number)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(QuotaVisualState(value).color(for: .dark))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 12)
            .background(.white.opacity(style == .soft ? 0.1 : 0.07),
                        in: RoundedRectangle(cornerRadius: style == .soft ? 28 : 10, style: .continuous))
            .overlay(alignment: .bottom) {
                if value.visibleBps != nil {
                    QuotaStyledProgress(value: value, style: style, height: 4)
                        .padding(.horizontal, style == .soft ? 24 : 10)
                        .padding(.bottom, style == .soft ? 6 : 4)
                }
            }
        }
        .buttonStyle(StudioPressButtonStyle())
        .accessibilityLabel(IslandSummaryText.accessibilityLabel(
            title: value.window.shortDisplayName,
            number: value.number,
            status: value.status
        ))
    }
}

private struct StudioPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

@MainActor
struct MacStudioDashboard: View {
    @ObservedObject var model: MacModel
    let fixture: [QuotaPresentation]?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var route = StudioRoute.overview
    @State private var selectedWindowID: String?
    @State private var showsBillingInspector = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let values = fixture ?? model.snapshot?.windows.map { QuotaPresentation(window: $0, now: context.date) } ?? []
            HStack(spacing: 0) {
                StudioSidebar(route: $route,
                              connected: fixture != nil || model.connected,
                              reduceTransparency: reduceTransparency,
                              quotaCount: values.count, alertCount: values.filter { model.billing.severity(for: $0.window) != .normal }.count)
                    .frame(width: 176)
                StudioDivider(vertical: true)
                ZStack {
                    PaperInk(scheme).canvas.ignoresSafeArea()
                    workspace(values)
                        .id(route)

                }
            }
            .foregroundStyle(PaperInk(scheme).ink)
            .background(PaperInk(scheme).canvas)

            .onExitCommand {
                if showsBillingInspector { showsBillingInspector = false }
                else if route == .overview { NSApp.keyWindow?.performClose(nil) }
                else { route = .overview }
            }
            .onChange(of: values.map(\.window.id)) { _, ids in
                if let selectedWindowID, ids.contains(selectedWindowID) { return }
                self.selectedWindowID = ids.first
            }
            .onAppear {
                if selectedWindowID == nil { selectedWindowID = values.first?.window.id }
            }
        }
        .inspector(isPresented: $showsBillingInspector) {
            let values = fixture ?? model.snapshot?.windows.map { QuotaPresentation(window: $0, now: Date()) } ?? []
            if let value = values.first(where: { $0.window.id == selectedWindowID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Text(L("billing.details")).font(.headline)
                            Spacer()
                            Button { showsBillingInspector = false } label: { Image(systemName: "xmark") }
                                .accessibilityLabel(L("settings.connections.close"))
                        }
                        BillingMetricDetails(value: value)
                        Divider()
                        BillingRuleEditor(window: value.window, monitor: model.billing).disabled(fixture != nil)
                    }.padding(20)
                }.inspectorColumnWidth(min: 280, ideal: 280, max: 320)
            }
        }
        .onChange(of: route) { _, _ in showsBillingInspector = false }
        .studioType(.body)
        .frame(minWidth: 820, idealWidth: 1080, minHeight: 560, idealHeight: 700)
    }

    @ViewBuilder
    private func workspace(_ values: [QuotaPresentation]) -> some View {
        switch route {
        case .overview:
            overviewWorkspace(values)
        case .usage:
            TokenUsageView(model: model, fixtureMode: fixture != nil, onOpenSettings: { route = .sync })
        case .alerts:
            BillingAlertsView(values: values, monitor: model.billing, resetReminders: model.resetReminders, fixtureMode: fixture != nil)
        case .accounts:
            accountsWorkspace
        case .sync:
            syncWorkspace
        }
    }

    private func overviewWorkspace(_ values: [QuotaPresentation]) -> some View {
        let groups = QuotaAccountGroup.grouped(values)
        let latestObservation = values.compactMap { $0.window.observedAt.flatMap(QuotaRules.date) }.max()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioHeader(
                    eyebrow: "",
                    title: L("island.dashboard.overviewTitle"),
                    detail: L("island.dashboard.summary", groups.count, values.count, Set(values.map { $0.window.providerId }).count)
                ) {
                    HStack(spacing: 12) {
                        if let latestObservation {
                            Text(L("island.dashboard.lastCollect", latestObservation.formatted(date: .omitted, time: .shortened)))
                                .studioType(.caption)
                                .foregroundStyle(PaperInk(scheme).muted)
                        }
                        if let progress = model.collectionProgress {
                            ProgressView(value: Double(progress.completed), total: Double(progress.total))
                                .frame(width: 72)
                                .accessibilityLabel(L("mac.refresh.progress", progress.completed, progress.total))
                            Text(progress.providerID.map {
                                L("mac.refresh.fetching", ProviderCatalog.identity(for: $0).displayName,
                                  progress.completed, progress.total)
                            } ?? L("mac.refresh.progress", progress.completed, progress.total))
                                .studioType(.caption)
                                .foregroundStyle(PaperInk(scheme).muted)
                        }
                        if fixture == nil {
                            Button {
                                model.refresh()
                            } label: {
                                Label(L("island.action.refresh"), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(StudioRaisedButtonStyle())
                            .disabled(!model.connected || model.collectionProgress != nil)
                        }
                    }
                }

                if fixture != nil {
                    Label(L("island.fixture.banner"), systemImage: "testtube.2")
                        .studioType(.caption)
                        .foregroundStyle(PaperInk(scheme).muted)
                }

                if fixture == nil, !values.isEmpty, !model.connected || values.contains(where: \.isHistorical) {
                    HStack(spacing: 14) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.connected ? L("island.dashboard.staleTitle") : L("island.dashboard.historyTitle")).studioType(.section)
                            Text(model.connected
                                 ? L("island.dashboard.staleDetail")
                                 : L("island.dashboard.historyDetail"))
                                .studioType(.body)
                        }
                        Spacer(minLength: 8)
                        Button(model.connecting ? L("island.state.connecting") : (model.connected ? L("island.dashboard.viewAccountStatus") : L("island.dashboard.connectSource"))) { route = .accounts }
                            .buttonStyle(StudioRaisedButtonStyle())
                            .disabled(model.connecting)
                    }
                    .padding(16)
                    .foregroundStyle(PaperInk(scheme).ink)
                    .studioSurface(radius: 14)
                    .accessibilityIdentifier("dashboard-history-notice")
                }

                if values.isEmpty {
                    EmptyState()
                        .frame(maxWidth: .infinity, minHeight: 330)
                        .studioSurface(radius: 18)
                } else {
                    BillingOverview(values: values, monitor: model.billing, fixtureMode: fixture != nil) { value in
                        selectedWindowID = value.window.id; showsBillingInspector = true
                    }
                }

                if fixture == nil, !model.message.isEmpty {
                    Label(model.message.text, systemImage: "info.circle")
                        .studioType(.caption)
                        .foregroundStyle(PaperInk(scheme).muted)
                }
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
        }
    }

    private var accountsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioHeader(
                    eyebrow: "",
                    title: L("island.accounts.title"),
                    detail: ""
                )
                if fixture != nil {
                    ContentUnavailableView(L("island.fixture.modeTitle"),
                                           systemImage: "testtube.2",
                                           description: Text(L("island.fixture.modeAccountsDetail")))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ProviderConnectionsView(model: model)
                        .frame(minHeight: 540)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private var syncWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioHeader(
                    eyebrow: "",
                    title: L("compact.settings"),
                    detail: ""
                )
                if fixture != nil {
                    ContentUnavailableView(L("island.fixture.modeTitle"),
                                           systemImage: "iphone.and.arrow.forward",
                                           description: Text(L("island.fixture.modePairingDetail")))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    MacTokenUsageOptions(model: model)
                    IslandAppearanceCard()
                    MacRefreshOptions(model: model)
                    MacSyncOptions(model: model)
                    MacLanguageCard()
                    if model.cfSyncEnabled { MacPairingCard(model: model) }
                    if model.cfSyncEnabled && model.cloudConnected { MacExternalToolsOptions(model: model) }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

private enum StudioRoute: String, CaseIterable {
    case overview, usage, alerts, accounts, sync

    var title: String {
        switch self {
        case .overview: L("phone.section.overview")
        case .usage: L("tokenUsage.title")
        case .alerts: L("billing.alertsTitle")
        case .accounts: L("compact.accounts")
        case .sync: L("compact.settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "list.bullet.rectangle"
        case .usage: "chart.bar.fill"
        case .alerts: "bell.badge"
        case .accounts: "person.crop.circle.badge.checkmark"
        case .sync: "gearshape"
        }
    }
}

private struct StudioSidebar: View {
    @Binding var route: StudioRoute
    let connected: Bool
    let reduceTransparency: Bool
    let quotaCount: Int
    let alertCount: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PaperInk(scheme)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ammo").studioType(.section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 16)

            ForEach(StudioRoute.allCases, id: \.self) { item in
                Button {
                    route = item
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(item.title).font(.system(size: 13, weight: route == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if item == .overview || item == .alerts {
                            Text(String(item == .overview ? quotaCount : alertCount))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
                        }
                    }
                    .foregroundStyle(route == item ? palette.ink : palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(route == item ? palette.ink.opacity(scheme == .dark ? 0.09 : 0.065) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                }
                .buttonStyle(StudioPressButtonStyle())
                .accessibilityAddTraits(route == item ? .isSelected : [])
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? Color.green : palette.muted.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(connected ? L("island.sidebar.connected") : L("island.sidebar.waiting"))
                    .studioType(.caption)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .padding(16)
        }
        .padding(.horizontal, 8)
        .background(palette.surface)
    }
}

private struct StudioHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let detail: String
    let trailing: Trailing

    init(eyebrow: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .studioType(.caption).fontWeight(.semibold)
                        .tracking(0)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .studioType(.title)
                if !detail.isEmpty {
                    Text(detail)
                        .studioType(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing
        }
    }
}

private extension StudioHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, detail: String) {
        self.init(eyebrow: eyebrow, title: title, detail: detail) { EmptyView() }
    }
}
