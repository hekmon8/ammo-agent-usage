import SwiftUI
import QuotaDesign
import QuotaCore
import QuotaSync
import QuotaCollector

struct MacTokenUsageOptions: View {
    @ObservedObject var model: MacModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("tokenUsage.settings.title")).studioType(.section)
            // Consent stays operable while reading so Stop can cancel the scan.
            Toggle(L("tokenUsage.optIn.title"), isOn: Binding(
                get: { model.tokenUsageEnabled },
                set: { enabled in Task { await model.setTokenUsageEnabled(enabled) } }
            )).accessibilityIdentifier("tokenUsageConsent")
            Text(L("tokenUsage.optIn.description")).studioType(.caption).foregroundStyle(.secondary)
            if model.tokenUsageEnabled {
                Picker(L("tokenUsage.timeZone"), selection: Binding(
                    get: { model.tokenUsageTimeZoneIdentifier },
                    set: { identifier in Task { await model.rescanTokenUsage(timeZoneIdentifier: identifier) } }
                )) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 420).disabled(model.tokenUsageBusy)
                    .accessibilityIdentifier("tokenUsageTimeZone")
                Text(L("tokenUsage.timeZone.rescan")).studioType(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).studioSurface(radius: 11).studioType(.body)
    }
}

struct MacRefreshOptions: View {
    @ObservedObject var model: MacModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.refresh.title")).studioType(.section)
            Picker(L("settings.refresh.interval"), selection: Binding(
                get: { model.refreshInterval },
                set: { model.setRefreshInterval($0) })) {
                ForEach(CollectorRefreshInterval.allCases, id: \.self) { interval in
                    Text(L("settings.refresh.minutes", interval.rawValue)).tag(interval)
                }
            }
            .accessibilityIdentifier("collectorRefreshInterval")
            .frame(maxWidth: 320, alignment: .leading)
            Text(L("settings.refresh.help"))
                .studioType(.caption).foregroundStyle(.secondary)
        }.padding(18).studioSurface(radius: 11).studioType(.body)
    }
}

struct MacSyncOptions: View {
    @ObservedObject var model: MacModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("settings.sync.chooseMethod")).studioType(.section)
            Text(L("settings.sync.chooseHelp"))
                .studioType(.caption).foregroundStyle(.secondary)
            Toggle(L("settings.sync.icloudToggle"), isOn: Binding(get: { model.iCloudEnabled }, set: { model.setICloudEnabled($0) }))
            Text(L("settings.sync.icloudHelp"))
                .studioType(.caption).foregroundStyle(.secondary)
            Text(model.iCloudMessage.text).studioType(.caption)
            if model.iCloudEnabled { Button(L("settings.sync.retryICloud")) { model.retryICloud() } }
            StudioDivider()
            Toggle(L("settings.sync.pairingToggle"), isOn: Binding(get: { model.cfSyncEnabled }, set: { model.setCFSyncEnabled($0) })).disabled(model.mcpBusy || model.cfSwitchBusy || model.workerSwitchPending)
            Text(L("settings.sync.pairingHelp"))
                .studioType(.caption).foregroundStyle(.secondary)

        }.padding(18).studioSurface(radius: 11).studioType(.body).buttonStyle(StudioRaisedButtonStyle())
    }
}

struct MacLanguageCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("language.title")).studioType(.section)
            Picker(L("language.title"), selection: Binding(
                get: { L10n.currentSetting },
                set: { L10n.setLanguage($0) })) {
                ForEach(QuotaLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Text(L("language.footer"))
                .studioType(.caption).foregroundStyle(.secondary)
        }.padding(18).studioSurface(radius: 11).studioType(.body)
    }
}

struct MacExternalToolsOptions: View {
    @ObservedObject var model: MacModel
    var body: some View {
        DisclosureGroup(L("settings.mcp.disclosure")) {
            VStack(alignment: .leading, spacing: 12) {
            if model.cfSyncEnabled && model.cloudConnected {
                StudioDivider()
                Text(L("settings.mcp.sectionTitle")).studioType(.section)
                Toggle(L("settings.mcp.shareToggle"), isOn: Binding(get: { model.mcpEnabled }, set: { value in Task { await model.setMCPEnabled(value) } }))
                    .disabled(model.mcpBusy || model.workerSwitchPending || model.rotationPending || model.rotationBusy)
                Text(L("settings.mcp.shareHelp"))
                    .studioType(.caption).foregroundStyle(.secondary)
                Text(model.mcpMessage.text).studioType(.caption)
                if model.mcpPending {
                    Button(L("settings.mcp.retryRevoke")) { Task { await model.setMCPEnabled(false) } }.disabled(model.mcpBusy || model.rotationBusy)
                }
                if model.mcpEnabled {
                    HStack(spacing: 10) {
                        Text(model.mcpEndpoint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MCPCopyButton(iconOnly: true, title: L("settings.mcp.copyEndpoint")) { model.copyMCPEndpoint() }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .help(model.mcpEndpoint)
                    HStack {
                        MCPCopyButton(title: L("settings.mcp.copyToken")) { model.copyMCPToken() }
                        MCPCopyButton(title: L("settings.mcp.copyClientConfig")) { model.copyMCPClientConfig() }
                            .disabled(model.mcpPending)
                        Button(L("settings.mcp.rotateToken")) { Task { await model.setMCPEnabled(true) } }.disabled(model.mcpBusy)
                    }
                    Text(L("settings.mcp.clientConfigHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L("settings.mcp.setupGuide")) {
                    Text(L("settings.mcp.guideSteps"))
                        .studioType(.caption).textSelection(.enabled)
                    Text(L("settings.mcp.headerRequirement"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
            }
            }.padding(.top, 12)
        }
        .padding(18)
        .studioSurface(radius: 11).studioType(.body).buttonStyle(StudioRaisedButtonStyle())
    }
}

/// Copy action with in-place confirmation; the shared status line alone is too far
/// from the pointer to confirm what was copied.
private struct MCPCopyButton: View {
    var iconOnly = false
    let title: String
    let copy: () -> Bool
    @State private var confirmed = false
    @State private var reset: Task<Void, Never>?
    var body: some View {
        Button {
            guard copy() else { return }
            confirmed = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                confirmed = false
            }
        } label: {
            if iconOnly {
                Label(title, systemImage: confirmed ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(confirmed ? L("settings.mcp.copiedWithTitle", title) : title)
            } else {
                Label(confirmed ? L("settings.mcp.copied") : title, systemImage: confirmed ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(StudioRaisedButtonStyle(iconOnly: iconOnly))
        .help(title)
    }
}

struct IslandAppearanceCard: View {
    @AppStorage(QuotaAppearanceKeys.displayStyle) private var style = QuotaDisplayStyle.calibrated.rawValue
    @AppStorage(QuotaAppearanceKeys.edgeMotion) private var edgeMotion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("settings.island.appearanceTitle")).studioType(.section)
            Text(L("settings.island.appearanceHelp"))
                .studioType(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(QuotaDisplayStyle.allCases) { option in
                    Button { style = option.rawValue } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(option.title).studioType(.section)
                                Spacer()
                                Image(systemName: style == option.rawValue ? "checkmark.circle.fill" : "circle")
                            }
                            Text(description(option)).studioType(.caption).foregroundStyle(.secondary)
                            preview(option).frame(height: 42).accessibilityHidden(true)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(style == option.rawValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .studioSurface(radius: 8)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(style == option.rawValue ? .isSelected : [])
                }
            }
            Toggle(L("settings.island.edgeGlowToggle"), isOn: $edgeMotion)
            Text(L("settings.island.autoCollapseHelp"))
                .studioType(.caption).foregroundStyle(.secondary)
        }.padding(20).studioSurface(radius: 11).studioType(.body).buttonStyle(StudioRaisedButtonStyle())
            .onChange(of: style) { _, _ in
                NotificationCenter.default.post(name: QuotaAppearanceKeys.islandLayoutChanged, object: nil)
            }
    }

    private func description(_ style: QuotaDisplayStyle) -> String {
        switch style {
        case .contour: L("settings.island.styleContour")
        case .calibrated: L("settings.island.styleCalibrated")
        case .soft: L("settings.island.styleSoft")
        case .ring: L("settings.island.styleRing")
        }
    }

    @ViewBuilder private func preview(_ style: QuotaDisplayStyle) -> some View {
        switch style {
        case .contour:
            HStack { ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1) } }
        case .calibrated:
            VStack(spacing: 6) {
                ForEach(0..<3) { _ in HStack(spacing: 3) { ForEach(0..<16) { _ in Rectangle().fill(.secondary.opacity(0.55)) } } }
            }
        case .soft:
            VStack(spacing: 6) { ForEach(0..<2) { _ in Capsule().fill(.secondary.opacity(0.2)) } }
        case .ring:
            HStack(spacing: 10) {
                ForEach(0..<2) { _ in
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                        Circle().trim(from: 0, to: 0.68)
                            .stroke(.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 30, height: 30)
                }
            }
        }
    }
}
