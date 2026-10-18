import AppKit
import QuotaCore
import QuotaDesign
import QuotaProviders
import QuotaSync
import SwiftUI

@MainActor
struct ProviderConnectionsView: View {
    @ObservedObject var model: MacModel
    var fixtureConnections: [ProviderConnectionSummary]? = nil
    private var connections: [ProviderConnectionSummary] { fixtureConnections ?? model.providerConnections }
    @State private var adding = false
    @State private var addingProvider = "codex"
    @State private var replacingConnectionID: String?
    @State private var sharingConnection: ProviderConnectionSummary?
    @State private var githubBillingConnection: ProviderConnectionSummary?
    @State private var showsReceivedShares = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("settings.connections.accountCount", connections.count)).studioType(.caption).foregroundStyle(.secondary)
                    }
                    Button(L("mac.share.receive")) { showsReceivedShares = true }
                        .buttonStyle(StudioRaisedButtonStyle()).controlSize(.large)
                    Spacer()
                    Button { replacingConnectionID = nil; addingProvider = "codex"; adding = true } label: { Label(L("settings.connections.addAccount"), systemImage: "plus") }
                        .buttonStyle(StudioRaisedButtonStyle()).controlSize(.large).disabled(model.connecting)
                }
                if connections.isEmpty {
                    ContentUnavailableView {
                        Label(L("settings.connections.emptyTitle"), systemImage: "square.stack.3d.up")
                    } description: {
                        Text(L("settings.connections.emptyDescription"))
                    } actions: {
                        Button(L("settings.connections.emptyAction")) { adding = true }.buttonStyle(StudioRaisedButtonStyle())
                    }.frame(minHeight: 300)
                } else {
                    VStack(spacing: 0) {
                        ForEach(connectionGroups) { group in
                            providerGroupCard(group)
                        }
                    }.studioSurface(radius: 11)
                }
                Label(L("settings.connections.privacyNote"), systemImage: "lock.shield")
                    .studioType(.caption).foregroundStyle(.secondary)
                if !model.providerConnectionError.isEmpty {
                    Text(model.providerConnectionError.text).studioType(.body).foregroundStyle(.red)
                }
            }.padding(0).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .disabled(fixtureConnections != nil)
        .sheet(isPresented: $adding) {
            let previous = connections.first { $0.id == replacingConnectionID }
            let scope = model.githubReconnectScope(connectionID: replacingConnectionID)
            AddProviderAccountView(model: model, selectedProvider: addingProvider, replacingConnectionID: replacingConnectionID,
                initialAlias: previous?.accountAlias ?? "",
                initialCodexAmbient: previous.map { $0.usesAmbientLogin && $0.providerID == "codex" } ?? true,
                initialLocalAmbient: previous.map(\.usesAmbientLogin) ?? true,
                initialOrganization: previous?.organizationID ?? scope.organization ?? "",
                initialScopeUnavailable: scope.isUnavailable)
        }
        .sheet(item: $sharingConnection) { connection in
            MacAccountSharesView(model: model, connection: connection)
        }
        .sheet(item: $githubBillingConnection) { connection in
            GitHubBillingDetailsView(model: model, connection: connection)
        }
        .sheet(isPresented: $showsReceivedShares) {
            MacReceivedSharesView(model: model)
        }
    }

    /// Accounts bucketed per provider in first-appearance order, so multiple
    /// instances of one provider share a single card.
    private var connectionGroups: [ProviderConnectionGroup] {
        var order: [String] = []
        var buckets: [String: [ProviderConnectionSummary]] = [:]
        for connection in connections {
            if buckets[connection.providerID] == nil { order.append(connection.providerID) }
            buckets[connection.providerID, default: []].append(connection)
        }
        return order.map { providerID in
            let bucket = buckets[providerID] ?? []
            return ProviderConnectionGroup(providerID: providerID,
                                           displayName: bucket.first?.displayName ?? providerID,
                                           connections: bucket)
        }
    }

    private func providerGroupCard(_ group: ProviderConnectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ProviderBrandAsset(providerID: group.providerID)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName).studioType(.section)
                    // The badge only earns its place when a provider actually
                    // has several instances grouped together.
                    if group.connections.count > 1 {
                        Text(L("settings.connections.providerInstanceCount", group.connections.count))
                            .studioType(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(L("compact.island"), isOn: Binding(
                    get: { model.islandProviders.includes(group.providerID) },
                    set: { model.setIslandProvider(group.providerID, visible: $0) }))
                    .toggleStyle(.checkbox).fixedSize()
                    .accessibilityLabel(group.displayName + " · " + L("compact.island"))
                Button {
                    addingProvider = group.providerID
                    replacingConnectionID = nil
                    adding = true
                } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("settings.connections.addSameProvider"))
                    .disabled(model.connecting)
            }.padding(.horizontal, 14).padding(.vertical, 9)
            StudioDivider()
            ForEach(group.connections) { connection in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.accountAlias).studioType(.body).fontWeight(.semibold)
                        Text(connection.method + " · " + connection.status)
                            .studioType(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if connection.providerID == "github-actions" {
                        Button(L("billing.github.details")) { githubBillingConnection = connection }
                            .disabled(model.connecting || model.shareBusy || !connection.isEnabled
                                || connection.statusKind == .reconnectStandalone || connection.statusKind == .paused
                                || connection.statusKind == .authNeedsUpdate)
                    }
                    Button(L("mac.share.manage")) { sharingConnection = connection }
                        .disabled(model.connecting)
                    Button(L("settings.connections.reconnect")) {
                        addingProvider = connection.providerID
                        replacingConnectionID = connection.id
                        adding = true
                    }.disabled(model.connecting || model.shareBusy)
                    Toggle(L("settings.connections.enabled"), isOn: Binding(
                        get: { connection.isEnabled },
                        set: { enabled in Task { await model.setConnectionEnabled(id: connection.id, enabled: enabled) } }))
                        .toggleStyle(.switch).fixedSize().disabled(model.connecting || model.shareBusy)
                        .accessibilityLabel(L("settings.connections.updateQuotaA11y", connection.accountAlias))
                    Menu {
                        Button(L("settings.connections.removeAccount"), role: .destructive) {
                            Task { await model.removeConnection(id: connection.id) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.connecting || model.shareBusy)
                }
                .padding(.leading, 44).padding(.trailing, 14).padding(.vertical, 9)
                if connection.id != group.connections.last?.id { StudioDivider().padding(.leading, 44) }
            }
        }
    }
}

/// One provider's connections rendered as a single grouped card.
private struct ProviderConnectionGroup: Identifiable {
    let providerID: String
    let displayName: String
    let connections: [ProviderConnectionSummary]
    var id: String { providerID }
}

@MainActor
struct AddProviderAccountView: View {
    var fixtureMode = false
    @ObservedObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    @State var selectedProvider: String
    let replacingConnectionID: String?
    @State private var codexAmbient = true
    @State private var localAmbient = true
    @State private var accountAlias = ""
    @State private var credentialKind: NativeProviderCredential.Kind = .apiKey
    @State private var credentialValue = ""
    @State private var organizationID = ""
    @State private var workspaceID = ""
    @State private var region = ""
    @State private var importedOAuthFile: URL?
    @State private var executablePath = ""
    @State private var discoveringCodex = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var initializedProvider: String?
    @State private var scopeConfirmed = false
    @State private var scopeUnavailable: Bool
    private let onFormState: ((Bool, String, Bool) -> Void)?

    init(fixtureMode: Bool = false, model: MacModel, selectedProvider: String = "codex", replacingConnectionID: String? = nil,
         initialAlias: String = "", initialCodexAmbient: Bool = true, initialLocalAmbient: Bool = true,
         initialOrganization: String = "", initialScopeUnavailable: Bool = false,
         onFormState: ((Bool, String, Bool) -> Void)? = nil) {
        self.fixtureMode = fixtureMode
        self.onFormState = onFormState
        _scopeUnavailable = State(initialValue: initialScopeUnavailable)
        _organizationID = State(initialValue: initialOrganization)
        self.model = model
        self.replacingConnectionID = replacingConnectionID
        _accountAlias = State(initialValue: initialAlias)
        _selectedProvider = State(initialValue: selectedProvider)
        _codexAmbient = State(initialValue: initialCodexAmbient)
        _localAmbient = State(initialValue: initialLocalAmbient)
        _credentialKind = State(initialValue: NativeProvider.supportedCredentialKinds(providerID: selectedProvider)
            .sorted { $0.rawValue < $1.rawValue }.first ?? .apiKey)
    }

    private var descriptor: NativeProviderDescriptor {
        NativeProviderCatalog.descriptor(for: selectedProvider) ?? NativeProviderCatalog.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(replacingConnectionID == nil ? L("settings.connections.addAccount") : L("settings.connections.reconnectAccount")).studioType(.title)
                Spacer()
                Button(action: cancel) { Image(systemName: "xmark").font(.caption.weight(.semibold)).padding(5) }
                    .buttonStyle(StudioRaisedButtonStyle(iconOnly: true)).accessibilityLabel(L("settings.connections.close"))
            }.padding(22)
            StudioDivider()
            HStack(spacing: 0) {
                providerList.frame(width: 176).disabled(replacingConnectionID != nil)
                StudioDivider(vertical: true)
                connectionSummary.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.disabled(model.connecting || connectionTask != nil)
            StudioDivider()
            HStack {
                Label(L("settings.connections.authLocalNote"), systemImage: "lock.fill").studioType(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("settings.connections.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(action: connect) {
                    HStack(spacing: 7) {
                        if model.connecting { ProgressView().controlSize(.small) }
                        Text(model.connecting ? L("settings.connections.connecting")
                            : (selectedProvider == "github-actions" ? L("billing.github.verifyAndSave") : selectedProvider == "codex" ? L("settings.connections.signInAndConnect") : L("settings.connections.verifyAndConnect")))
                    }
                }.buttonStyle(StudioRaisedButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }.padding(20)
        }
        .studioType(.body)
        .buttonStyle(StudioRaisedButtonStyle())
        .frame(width: 680, height: 600)
        .task(id: "\(selectedProvider)-\(codexAmbient)") {
            guard !fixtureMode else { return }
            model.providerConnectionError = LocalizedStatus.empty
            let isInitial = initializedProvider == nil
            initializedProvider = selectedProvider
            if !isInitial, selectedProvider == "github-actions" { localAmbient = true }
            credentialValue = ""
            importedOAuthFile = nil
            if !isInitial { organizationID = "" }
            workspaceID = ""
            region = ""
            executablePath = ""
            credentialKind = credentialKinds.first ?? .apiKey
            onFormState?(localAmbient, organizationID, canConnect)
            if selectedProvider == "codex", !codexAmbient {
                discoveringCodex = true
                defer { discoveringCodex = false }
                let detected = await Task.detached(priority: .utility) { CodexAppDiscovery.installedApp() }.value
                guard !Task.isCancelled else { return }
                executablePath = detected?.path ?? ""
            }
        }
        .onChange(of: model.connecting) { _, _ in onFormState?(localAmbient, organizationID, canConnect) }
        .onDisappear { connectionTask?.cancel() }
    }

    private var providerList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(NativeProviderCatalog.all) { provider in
                    Button { selectedProvider = provider.id } label: {
                        HStack(spacing: 10) {
                            ProviderBrandAsset(providerID: provider.id).frame(width: 19, height: 19)
                            Text(provider.displayName).studioType(.body).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedProvider == provider.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(10)
        }.background(.quaternary.opacity(0.2))
    }

    private var connectionSummary: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                ProviderBrandAsset(providerID: selectedProvider).frame(width: 34, height: 34)
                Text(descriptor.displayName).studioType(.section)
            }
            if selectedProvider == "codex" {
                Picker(L("settings.codex.signInMethod"), selection: $codexAmbient) {
                    Text(L("settings.connect.existingLocalLogin")).tag(true)
                    Text(L("settings.connect.separateLogin")).tag(false)
                }.pickerStyle(.segmented)
                if codexAmbient {
                    Text(L("settings.codex.localHelp"))
                        .studioType(.body).foregroundStyle(.secondary)
                    Label(L("settings.codex.signInFirst"), systemImage: "person.crop.circle.badge.checkmark")
                        .studioType(.body)
                } else {
                    Text(L("settings.codex.nativeHelp"))
                        .studioType(.body).foregroundStyle(.secondary)
                    HStack {
                        Text(discoveringCodex ? L("settings.codex.discovering") : (executablePath.isEmpty ? L("settings.codex.notFound") : L("settings.codex.found")))
                        Spacer()
                        Button(L("settings.connect.chooseApp"), action: chooseExecutable)
                    }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            } else if selectedProvider == "zcode" {
                Text(L("catalog.help.zcode"))
                    .studioType(.body).foregroundStyle(.secondary)
                TextField(L("settings.account.aliasPlaceholder"), text: $accountAlias)
                    .textFieldStyle(.roundedBorder)
            } else if hasLocalLogin {
                Picker(L("settings.connect.connectMethod"), selection: $localAmbient) {
                    Text(L("settings.connect.existingLocalLogin")).tag(true)
                    Text(L("settings.connect.manualAuth")).tag(false)
                }.pickerStyle(.segmented)
                TextField(L("settings.account.aliasPlaceholder"), text: $accountAlias)
                    .textFieldStyle(.roundedBorder)
                if localAmbient {
                    Text(L(localHelpKey)).studioType(.body).foregroundStyle(.secondary)
                    if selectedProvider == "github-actions" {
                        DisclosureGroup(L("billing.github.connectionDetails")) {
                            Text(L("billing.github.cli.details")).studioType(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    SecureField(credentialLabel(credentialKind), text: $credentialValue)
                        .textFieldStyle(.roundedBorder)
                    if let guide = credentialGuide {
                        if selectedProvider == "github-actions" {
                            DisclosureGroup(L("billing.github.connectionDetails")) {
                                guideText(guide).studioType(.caption)
                            }
                        } else { VStack(alignment: .leading, spacing: 7) {
                            Label(L("settings.credential.guide.title"), systemImage: "book.page")
                                .studioType(.caption)
                            guideText(guide).studioType(.caption)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    Text(L("settings.credential.genericHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
                if selectedProvider == "github-actions" {
                    TextField(L("billing.github.organizationPlaceholder"), text: $organizationID).textFieldStyle(.roundedBorder)
                    if scopeUnavailable {
                        Text(L("billing.github.scopeUnavailable")).studioType(.caption).foregroundStyle(.secondary)
                        Toggle(L("billing.github.confirmScope"), isOn: $scopeConfirmed).studioType(.caption)
                    }
                }
            } else {
                Text(descriptor.connectionHelp)
                    .studioType(.body).foregroundStyle(.secondary)
                TextField(L("settings.account.aliasPlaceholder"), text: $accountAlias)
                    .textFieldStyle(.roundedBorder)
                if credentialKinds.count > 1 {
                  Picker(L("settings.credential.method"), selection: $credentialKind) {
                    ForEach(credentialKinds, id: \.self) { kind in
                        Text(credentialLabel(kind)).tag(kind)
                    }
                  }
                }
                if selectedProvider != "antigravity" {
                  SecureField(credentialLabel(credentialKind), text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
                }
                if let guide = credentialGuide {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(L("settings.credential.guide.title"), systemImage: "book.page")
                            .studioType(.caption)
                        guideText(guide).studioType(.caption)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                if selectedProvider == "zai" {
                    Picker(L("settings.zai.region"), selection: $region) {
                        Text(L("settings.zai.regionPlaceholder")).tag("")
                        Text(L("settings.zai.regionChina")).tag("bigmodel-cn")
                        Text(L("settings.zai.regionGlobal")).tag("global")
                    }
                    DisclosureGroup(L("settings.zai.teamAccount")) {
                        TextField(L("settings.zai.orgPlaceholder"), text: $organizationID).textFieldStyle(.roundedBorder)
                        TextField(L("settings.zai.projectPlaceholder"), text: $workspaceID).textFieldStyle(.roundedBorder)
                    }
                    Text(L("settings.zai.regionHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
                if selectedProvider == "cloudflare" {
                    TextField(L("billing.accountID"), text: $organizationID).textFieldStyle(.roundedBorder)
                }
                if selectedProvider == "vercel" {
                    TextField(L("billing.teamID"), text: $organizationID).textFieldStyle(.roundedBorder)
                }
                if selectedProvider == "github-actions" {
                    TextField(L("billing.github.organizationPlaceholder"), text: $organizationID).textFieldStyle(.roundedBorder)
                }
                if selectedProvider == "opencodego" {
                    TextField(L("settings.opencodego.workspacePlaceholder"), text: $workspaceID).textFieldStyle(.roundedBorder)
                }
                if selectedProvider == "antigravity" {
                    Text(L("settings.agy.importHelp"))
                        .studioType(.body).foregroundStyle(.secondary)
                    HStack {
                        Button(L("settings.agy.chooseAuthFile")) { chooseOAuthFile() }
                        if let importedOAuthFile {
                            Label(importedOAuthFile.lastPathComponent, systemImage: "doc.badge.checkmark")
                                .studioType(.caption)
                            Button(L("settings.agy.pasteInstead")) { self.importedOAuthFile = nil }
                        }
                    }
                    if importedOAuthFile == nil {
                        SecureField(L("settings.credential.oauthJSON"), text: $credentialValue)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(L("settings.credential.antigravityHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("settings.credential.genericHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.providerConnectionError.isEmpty {
                Label(model.providerConnectionError.text, systemImage: "exclamationmark.circle")
                    .studioType(.body).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasLocalLogin: Bool { selectedProvider == "github-actions" || selectedProvider == "grok" || selectedProvider == "claude" || selectedProvider == "workbuddy" || selectedProvider == "zcode" }

    private var localHelpKey: String {
        switch selectedProvider {
        case "github-actions": "billing.github.cli.help"
        case "claude": "settings.claude.localHelp"
        case "workbuddy": "settings.workbuddy.localHelp"
        default: "settings.grok.localHelp"
        }
    }

    private var credentialKinds: [NativeProviderCredential.Kind] {
        NativeProvider.supportedCredentialKinds(providerID: selectedProvider).sorted { $0.rawValue < $1.rawValue }
    }
    private func credentialLabel(_ kind: NativeProviderCredential.Kind) -> String {
        switch kind {
        case .apiKey:
            if selectedProvider == "github-actions" { L("billing.github.existingToken") }
            else if selectedProvider == "workbuddy" { L("settings.credential.workbuddy.token") }
            else { L("settings.credential.apiToken") }
        case .cookie: selectedProvider == "deepseek" ? L("settings.credential.platformToken") : L("settings.credential.webCookie")
        case .oauth: selectedProvider == "antigravity" ? L("settings.credential.oauthJSON") : L("settings.credential.oauthToken")
        }
    }

    /// Step-by-step instructions for obtaining the currently selected credential,
    /// with markdown links to the provider's console page.
    private var credentialGuide: String? {
        switch (selectedProvider, credentialKind) {
        case ("zai", .apiKey): L("catalog.guide.zai.apiKey")
        case ("cloudflare", .apiKey): L("catalog.guide.cloudflare.apiKey")
        case ("replit", .apiKey): L("catalog.guide.replit.apiKey")
        case ("fal", .apiKey): L("catalog.guide.fal.apiKey")
        case ("vercel", .apiKey): L("catalog.guide.vercel.apiKey")
        case ("github-actions", .apiKey): L("catalog.guide.github-actions.apiKey")
        case ("openrouter", .apiKey): L("catalog.guide.openrouter.apiKey")
        case ("copilot", .apiKey): L("catalog.guide.copilot.apiKey")
        case ("deepseek", .apiKey): L("catalog.guide.deepseek.apiKey")
        case ("deepseek", .cookie): L("catalog.guide.deepseek.cookie")
        case ("opencodego", .apiKey): L("catalog.guide.opencodego.apiKey")
        case ("opencodego", .cookie): L("catalog.guide.opencodego.cookie")
        case ("factory", .apiKey): L("catalog.guide.factory.apiKey")
        case ("amp", .apiKey): L("catalog.guide.amp.apiKey")
        case ("manus", .cookie): L("catalog.guide.manus.cookie")
        case ("grok", .apiKey): L("catalog.guide.grok.apiKey")
        case ("grok", .cookie): L("catalog.guide.grok.cookie")
        case ("claude", .oauth): L("catalog.guide.claude.oauth")
        case ("workbuddy", .apiKey): L("catalog.guide.workbuddy.apiKey")
        default: nil
        }
    }

    private func guideText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }

    private var canConnect: Bool {
        if selectedProvider == "github-actions", scopeUnavailable, !scopeConfirmed { return false }
        guard connectionTask == nil, !model.connecting, accountAlias.count <= 48 else { return false }
        if selectedProvider == "codex" { return codexAmbient || !executablePath.isEmpty }
        if selectedProvider == "zcode" { return true }
        if selectedProvider == "github-actions", !organizationID.isEmpty, !GitHubBillingReader.validOwner(organizationID) { return false }
        if hasLocalLogin && localAmbient { return true }
        if selectedProvider == "cloudflare", organizationID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) == nil { return false }
        if selectedProvider == "vercel", organizationID.range(of: "^team_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) == nil { return false }
        if selectedProvider == "zai" {
            guard !region.isEmpty, organizationID.isEmpty == workspaceID.isEmpty else { return false }
        }
        if selectedProvider == "antigravity" {
            return importedOAuthFile != nil || !credentialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !credentialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard canConnect else { return }
        let providerID = selectedProvider
        if selectedProvider == "codex" && codexAmbient {
            let alias = accountAlias
            connectionTask = Task {
                await model.connectAmbientLogin(providerID: "codex", alias: alias,
                                                replacingConnectionID: replacingConnectionID)
                guard !Task.isCancelled else { return }
                connectionTask = nil
                if model.providerConnectionError.isEmpty { dismiss() }
            }
            return
        }
        if selectedProvider == "zcode" || (hasLocalLogin && localAmbient) {
            let alias = accountAlias
            let organization = organizationID
            connectionTask = Task {
                await model.connectAmbientLogin(providerID: providerID, alias: alias,
                                                replacingConnectionID: replacingConnectionID,
                                                organizationID: organization.isEmpty ? nil : organization)
                guard !Task.isCancelled else { return }
                connectionTask = nil
                if model.providerConnectionError.isEmpty { dismiss() }
            }
            return
        }
        let executable = providerID == "codex" ? URL(fileURLWithPath: executablePath) : nil
        let credential = providerID == "codex" ? nil : NativeProviderCredential(
            kind: credentialKind, value: credentialValue,
            organizationID: organizationID.isEmpty ? nil : organizationID,
            workspaceID: workspaceID.isEmpty ? nil : workspaceID,
            region: region.isEmpty ? nil : region)
        credentialValue = ""
        connectionTask = Task {
            var selectedCredential = credential
            if providerID == "antigravity" {
                do {
                    if let importedOAuthFile { selectedCredential = try AntigravityCredentialImport.read(importedOAuthFile) }
                    else { selectedCredential = try AntigravityCredentialImport.credential(from: Data((credential?.value ?? "").utf8)) }
                }
                catch {
                    model.providerConnectionError = LocalizedStatus("settings.agy.importFailed")
                    connectionTask = nil
                    return
                }
            }
            await model.connectProvider(
                providerID: providerID,
                alias: accountAlias,
                executableURL: executable, credential: selectedCredential, replacingConnectionID: replacingConnectionID)
            guard !Task.isCancelled else { return }
            connectionTask = nil
            if model.providerConnectionError.isEmpty { dismiss() }
        }
    }

    private func cancel() {
        connectionTask?.cancel()
        connectionTask = nil
        dismiss()
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { executablePath = url.path }
    }

    private func chooseOAuthFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importedOAuthFile = url; credentialValue = "" }
    }
}

@MainActor
struct SyncConnectionView: View {
    @ObservedObject var model: MacModel
    /// True when shown while a service is already connected, so confirming
    /// replaces it (official ↔ self-hosted) instead of a first-time setup.
    var allowsReplacement = false
    @State private var mode = SyncServiceCatalog.defaultMode
    @State private var endpoint = ""
    @State private var bootstrapToken = ""

    var body: some View {
        Form {
            Section {
                Text(L("settings.sync.intro"))
                    .studioType(.caption).foregroundStyle(.secondary)
                Picker(L("settings.sync.serviceSource"), selection: $mode) {
                    ForEach(SyncServiceCatalog.availableModes, id: \.self) { option in
                        Text(option == .official ? L("settings.sync.officialMode") : L("settings.sync.selfHostedMode")).tag(option)
                    }
                }.pickerStyle(.segmented)
                switch mode {
                case .official:
                    LabeledContent(L("settings.sync.endpointLabel")) {
                        Text(SyncServiceCatalog.officialEndpoint?.absoluteString ?? "")
                            .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                    Text(L("settings.sync.officialHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                case .selfHosted:
                    TextField(L("settings.sync.workerAddressPlaceholder"), text: $endpoint)
                    Text(L("settings.sync.selfHostedHelp"))
                        .studioType(.caption).foregroundStyle(.secondary)
                }
                SecureField(L("settings.sync.bootstrapTokenPlaceholder"), text: $bootstrapToken)
                Text(L("settings.sync.tokenHelp"))
                    .studioType(.caption).foregroundStyle(.secondary)
                Button(allowsReplacement ? L("settings.sync.switchWorker") : L("settings.sync.connectWorker")) {
                    guard let url = resolvedEndpoint else { return }
                    let token = bootstrapToken
                    bootstrapToken = ""
                    if allowsReplacement {
                        Task { await model.switchWorker(endpoint: url, bootstrapToken: token) }
                    } else {
                        Task { await model.connectWorker(endpoint: url, bootstrapToken: token) }
                    }
                }
                .disabled(model.cloudConnecting || model.workerSwitchPending || model.retiredServicePending || model.retiredCleanupBusy ||
                    (model.cloudConnected && !allowsReplacement) || resolvedEndpoint == nil || bootstrapToken.isEmpty)
                if model.workerSwitchPending {
                    Button(L("settings.sync.retrySwitch")) {
                        Task { await model.retryPendingWorkerSwitch() }
                    }
                    .disabled(model.cloudConnecting)
                    if model.workerSwitchCanContinue {
                        Button(L("settings.sync.continueSwitch")) {
                            Task { await model.continuePendingWorkerSwitchKeepingOldAccess() }
                        }
                        .disabled(model.cloudConnecting)
                    }
                    if model.workerSwitchCanCancel {
                        Button(L("settings.sync.cancelPendingSwitch")) {
                            Task { await model.cancelPendingWorkerSwitch() }
                        }
                        .disabled(model.cloudConnecting)
                    }
                }
                if model.retiredServicePending && !model.workerSwitchPending {
                    Button(L("settings.sync.retryOldRevocation")) {
                        Task { await model.retryRetiredServiceRevocation() }
                    }
                    .disabled(model.retiredCleanupBusy || model.cloudConnecting)
                    Text(model.retiredServiceMessage.text).studioType(.caption).foregroundStyle(.orange)
                }
                if model.cloudConnecting {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("settings.sync.connecting")) }
                        .studioType(.caption).foregroundStyle(.secondary)
                }
                if !model.syncMessage.isEmpty {
                    Text(model.syncMessage.text).studioType(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L("settings.sync.workerSection"))
            } footer: {
                Label(L("settings.sync.privacyNote"), systemImage: "lock.shield")
                    .studioType(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    /// Apply the same origin rules the transport will enforce, so invalid
    /// self-hosted addresses disable the button before any request is made.
    private var resolvedEndpoint: URL? {
        switch mode {
        case .official: return SyncServiceCatalog.endpoint(for: .official)
        case .selfHosted:
            guard let url = URL(string: endpoint), (try? SyncTransport(baseURL: url)) != nil else { return nil }
            return url
        }
    }
}

@MainActor
private struct MacAccountSharesView: View {
    @ObservedObject var model: MacModel
    let connection: ProviderConnectionSummary
    @Environment(\.dismiss) private var dismiss

    private var records: [ShareRecord] {
        model.shares.filter { $0.connectionId == connection.id && $0.providerId == connection.providerID }
    }

    var body: some View {
        let records = self.records
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(L("mac.share.title") + " · " + connection.accountAlias).studioType(.title)
                Spacer()
                Button(L("mac.share.close")) { dismiss() }
            }
            Text(L("mac.share.consent"))
                .studioType(.body).foregroundStyle(.secondary)
            if !model.canShare {
                Text(L("mac.share.notConfigured")).foregroundStyle(.orange)
            }
            HStack {
                Button(L("mac.share.create")) {
                    Task { await model.createShare(connectionID: connection.id) }
                }.disabled(!model.canShare || !connection.isEnabled || model.shareBusy)
                Button(L("mac.share.refresh")) { Task { await model.refreshShares() } }
                    .disabled(!model.canShare || model.shareBusy)
                if model.shareBusy { ProgressView().controlSize(.small) }
            }
            if !model.shareMessage.isEmpty {
                Text(model.shareMessage.text).studioType(.caption).foregroundStyle(.secondary)
            }
            if !model.shareInviteLink.isEmpty &&
                (records.first(where: { $0.shareId == model.shareInvitationID })?.state == "pending" ||
                 records.first(where: { $0.shareId == model.shareInvitationID }) == nil) {
                HStack(alignment: .top, spacing: 14) {
                    if let qr = pairingQRCode(model.shareInviteLink) {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 142, height: 142)
                            .accessibilityLabel(L("mac.share.qrAccessibility"))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let expiry = records.first(where: { $0.shareId == model.shareInvitationID })?.expiresAt {
                            Text(L("mac.share.inviteExpires", expiry))
                        } else {
                            Text(L("mac.share.inviteDuration"))
                        }
                        Button(L("mac.share.copyLink")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.shareInviteLink, forType: .string)
                        }
                    }.font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if records.isEmpty {
                        Text(L("mac.share.empty")).foregroundStyle(.secondary)
                    }
                    ForEach(records, id: \.shareId) { share in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(share.label).fontWeight(.semibold)
                                Spacer()
                                Text(stateText(share.state)).foregroundStyle(.secondary)
                            }
                            if let recipient = share.recipientName {
                                Text(recipient).font(.caption).foregroundStyle(.secondary)
                            }
                            if share.state == "claimed", let code = share.verificationCode {
                                Text(code).font(.caption.monospaced()).textSelection(.enabled)
                                Button(L("mac.share.approveButton")) {
                                    Task { await model.approveShare(share) }
                                }.disabled(model.shareBusy)
                            }
                            if share.state == "pending" {
                                Text(L("mac.share.inviteDuration")).font(.caption).foregroundStyle(.secondary)
                            }
                            if share.state != "revoked" {
                                Button(L("mac.share.revoke"), role: .destructive) {
                                    Task { await model.revokeShare(share) }
                                }.disabled(model.shareBusy)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 640, height: 620)
        .studioType(.body).buttonStyle(StudioRaisedButtonStyle())
        .task { await model.refreshShares() }
        .onDisappear { model.clearShareInvitation() }
    }

    private func stateText(_ state: String) -> String {
        switch state {
        case "pending": L("mac.share.state.pending")
        case "claimed": L("mac.share.state.claimed")
        case "approved": L("mac.share.state.approved")
        case "expired": L("mac.share.state.expired")
        case "revoked": L("mac.share.state.revoked")
        default: state
        }
    }
}

@MainActor
private struct MacReceivedSharesView: View {
    @ObservedObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("mac.share.receivedTitle")).studioType(.title)
                Spacer()
                Button(L("mac.share.close")) { dismiss() }
            }
            Text(L("mac.share.recipientPrivacy")).foregroundStyle(.secondary)
            TextField(L("mac.share.linkPlaceholder"), text: $link)
                .textFieldStyle(.roundedBorder)
            TextField(L("mac.share.recipientName"), text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(L("mac.share.claim")) {
                    Task {
                        let claimCount = model.receivedClaims.count
                        await model.claimSharedLink(link, recipientName: name)
                        if model.receivedClaims.count > claimCount { link = "" }
                    }
                }.disabled(model.receivingBusy || link.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("mac.share.refresh")) { Task { await model.refreshReceivedShares() } }
                    .disabled(model.receivingBusy)
                if model.receivingBusy { ProgressView().controlSize(.small) }
            }
            if !model.receivingMessage.isEmpty {
                Text(model.receivingMessage.text).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.receivedClaims, id: \.claimId) { claim in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("mac.share.claimPending"))
                            Text(L("mac.share.claimCode", claim.verificationCode))
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Button(L("mac.share.checkApproval")) {
                                Task { await model.refreshReceivedShares() }
                            }.disabled(model.receivingBusy)
                            Button(L("mac.share.removeLocal"), role: .destructive) {
                                model.removeReceivedShare(endpoint: claim.endpoint, shareID: claim.shareId)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.receivedGrants, id: \.shareId) { grant in
                        VStack(alignment: .leading, spacing: 9) {
                            if let projection = model.receivedProjection(for: grant) {
                                Text(projection.label).fontWeight(.semibold)
                                Text(L("mac.share.capturedAt", projection.capturedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(projection.windows.indices, id: \.self) { index in
                                    let window = projection.windows[index]
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(window.quotaKey).fontWeight(.medium)
                                        Text(windowDetails(window))
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Text(L("mac.share.waitingValues")).foregroundStyle(.secondary)
                            }
                            Button(L("mac.share.removeLocal"), role: .destructive) {
                                model.removeReceivedShare(endpoint: grant.endpoint, shareID: grant.shareId)
                            }
                        }.padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.receivedClaims.isEmpty && model.receivedGrants.isEmpty {
                        Text(L("mac.share.empty")).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 640, height: 620)
        .studioType(.body).buttonStyle(StudioRaisedButtonStyle())
        .task { await model.refreshReceivedShares() }
    }

    private func windowDetails(_ window: ShareWindow) -> String {
        var parts = [window.availability]
        if let bps = window.remainingBps {
            parts.append(String(format: "%.2f%%", Double(bps) / 100))
        }
        if let amount = window.amount {
            parts.append([amount, window.currency].compactMap { $0 }.joined(separator: " "))
        }
        if let limit = window.limit { parts.append("/ " + limit) }
        parts.append(window.quality + " · " + window.fetchOutcome)
        if let observed = window.observedAt { parts.append(observed) }
        if let stale = window.staleAt { parts.append(stale) }
        if let reset = window.resetsAt { parts.append(reset) }
        return parts.joined(separator: " · ")
    }
}
