import Foundation
import AppKit
import QuotaCore
import QuotaStore
import QuotaProviders
import QuotaCollector
import QuotaIPC
import QuotaSync
import QuotaDesign
import QuotaPhone
import CryptoKit

/// How an account updates its quota; `method` resolves the label at render time
/// so a language change re-renders rows instead of keeping capture-time text.
enum ConnectionMethodKind: Sendable {
    case nativeCodex
    case codexLocalLogin
    case grokLocalLogin
    case claudeLocalLogin
    case workbuddyLocalLogin
    case zcodeLocalLogin
    case githubCLILogin
    case nativeProvider
}

enum GitHubReconnectScope: Equatable {
    case known(String?), unavailable
    var organization: String? { if case let .known(value) = self { return value }; return nil }
    var isUnavailable: Bool { self == .unavailable }
    static func resolve(record: ProviderConnectionRecord?, loadOrganization: () throws -> String?) -> Self {
        guard let record, record.providerID == "github-actions" else { return .known(nil) }
        if let organization = record.organizationID { return .known(organization) }
        guard record.kind == .nativeProvider else { return .known(nil) }
        guard record.instanceID != nil else { return .unavailable }
        do { return .known(try loadOrganization()) } catch { return .unavailable }
    }
}

/// Durable ambient connection acceptance, with cancellation-independent rollback.
@MainActor
enum AmbientConnectionAcceptance {
    struct RecoveryFailure: Error {}
    static func prepared(previous: ProviderConnectionsConfiguration, record: ProviderConnectionRecord,
                         replacingID: String?) throws -> ProviderConnectionsConfiguration {
        var next = previous
        let replaced = next.connections.filter { $0.id == record.id || $0.id == replacingID }
        next.connections.removeAll { $0.id == record.id || $0.id == replacingID }
        next.connections.append(try record.validated())
        next.pendingInstanceRemovals = Array(Set((previous.pendingInstanceRemovals ?? []) + replaced.compactMap(\.instanceID))).sorted()
        return try next.validated()
    }
    static func commit(previous: ProviderConnectionsConfiguration, next: ProviderConnectionsConfiguration,
                       persist: @escaping (ProviderConnectionsConfiguration) throws -> Void,
                       install: @escaping (ProviderConnectionsConfiguration) -> Void,
                       activate: @escaping (ProviderConnectionsConfiguration) async throws -> Void,
                       pause: @escaping () async -> Void,
                       cleanup: (ProviderConnectionsConfiguration) -> ProviderConnectionsConfiguration) async throws -> ProviderConnectionsConfiguration {
        var persistenceAttempted = false
        do {
            try Task.checkCancellation()
            persistenceAttempted = true
            try persist(next)
            install(next)
            try await activate(next)
            try Task.checkCancellation()
            let accepted = cleanup(next)
            install(accepted)
            return accepted
        } catch {
            let original = error
            let recovered = await Task { @MainActor in
                do {
                    await pause()
                    if persistenceAttempted { try persist(previous) }
                    install(previous)
                    try await activate(previous)
                    return true
                } catch { return false }
            }.value
            guard recovered else { throw RecoveryFailure() }
            throw original
        }
    }
    static func cleanup(_ configuration: ProviderConnectionsConfiguration,
                        persist: (ProviderConnectionsConfiguration) throws -> Void,
                        removeCredential: (String) throws -> Void,
                        removeProfile: (String) throws -> Void) -> ProviderConnectionsConfiguration {
        var next = configuration
        next.pendingInstanceRemovals = (configuration.pendingInstanceRemovals ?? []).filter { reference in
            guard !configuration.connections.contains(where: { $0.instanceID == reference }) else { return true }
            do { try removeCredential(reference); try removeProfile(reference); return false }
            catch { return true }
        }
        guard next.pendingInstanceRemovals != configuration.pendingInstanceRemovals else { return configuration }
        do { try persist(next); return next }
        catch { return configuration }
    }

}

/// The refresh state behind a connection row's status line.
enum ConnectionStatusKind: Sendable {
    case reconnectStandalone
    case paused
    case authNeedsUpdate
    case throttled
    case updateIncomplete
    case waitingFirst
    case bound
}

struct ProviderConnectionSummary: Identifiable, Sendable {
    let id: String
    let providerID: String
    let displayName: String
    let accountAlias: String
    let methodKind: ConnectionMethodKind
    let statusKind: ConnectionStatusKind
    let isEnabled: Bool
    var usesAmbientLogin: Bool = false
    var organizationID: String? = nil

    var method: String {
        switch methodKind {
        case .nativeCodex: L("mac.method.nativeCodex")
        case .codexLocalLogin: L("mac.method.localCodex")
        case .grokLocalLogin: L("mac.method.localGrok")
        case .claudeLocalLogin: L("mac.method.localClaude")
        case .workbuddyLocalLogin: L("mac.method.localWorkBuddy")
        case .zcodeLocalLogin: L("mac.method.localZCode")
        case .githubCLILogin: L("mac.method.localGitHubCLI")
        case .nativeProvider: L("mac.method.standalone")
        }
    }

    var status: String {
        switch statusKind {
        case .reconnectStandalone: L("mac.status.reconnectStandalone")
        case .paused: L("mac.status.paused")
        case .authNeedsUpdate: L("mac.status.authNeedsUpdate")
        case .throttled: L("mac.status.throttled")
        case .updateIncomplete: L("mac.status.updateIncomplete")
        case .waitingFirst: L("mac.status.waitingFirst")
        case .bound: L("mac.status.bound")
        }
    }
}

/// Keeps paused accounts in retained snapshots without opening their credentials.
private struct PausedConnectionProvider: QuotaProvider {
    let definition: ProviderDefinition
    let accountID: String
    let credentialIdentity: String
    init(_ record: ProviderConnectionRecord) {
        definition = ProviderDefinition(id: record.providerID, displayName: record.accountAlias, source: .localRPC)
        accountID = record.accountID
        credentialIdentity = record.expectedIdentity
    }
    func fetch(now: Date) async throws -> [QuotaWindow] { throw ProviderFailure.authRequired }
}

/// The snapshot window budget is exhausted by already-connected accounts, so a
/// new connection has no room; distinct from a provider returning oversized data.
private struct WindowBudgetExceeded: Error {
    let proposed: Int
    let cap: Int
}
private struct ShareRevocationFailure: Error {}
private struct StoredReceivedShares: Codable {
    var claims: [ShareClaim]
    var grants: [ShareGrant]
}

/// Partial-read intent is independent of retained collector measurements.
struct GitHubPartialReadState {
    var retryDeadlines: [String: Date] = [:]
    var unavailableExpenses: [String: Date] = [:]
    mutating func observe(_ probe: NativeProviderProbeResult, now: Date = Date()) {
        retryDeadlines = retryDeadlines.filter { $0.value > now }
        let key = "github-actions/" + probe.accountID
        if let retry = probe.retryNotBefore { retryDeadlines[key] = max(retryDeadlines[key] ?? retry, retry) }
        if probe.windows.contains(where: { $0.availability == .unavailable }) {
            let observedAt = probe.expenseObservedAt ?? now
            unavailableExpenses[key] = max(unavailableExpenses[key] ?? observedAt, observedAt)
        }
        // An uninstalled successful probe cannot clear a retained failure.
    }
}

@MainActor
final class MacModel: ObservableObject {
    let billing = BillingMonitor()
    let resetReminders = ResetReminderCoordinator.local()
    @Published var snapshot: Snapshot?
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var tokenUsageLocalAnalysis: TokenUsageLocalAnalysis?
    @Published private(set) var tokenUsageEnabled = false
    @Published private(set) var tokenUsageBusy = false
    @Published private(set) var tokenUsageMessage: String?
    @Published private(set) var tokenUsageSyncMessage: String?
    @Published private(set) var tokenUsageTimeZoneIdentifier = TimeZone.current.identifier
    private var tokenUsageScan: Task<TokenUsageScanResult, Error>?
    private var tokenUsageLoop: Task<Void, Never>?
    private var tokenUsageGeneration = UUID()
    private let tokenUsageStorageURL: URL?
    private let tokenUsageDefaults: UserDefaults
    private let tokenUsageWrite: (Data, URL) throws -> Void
    private let tokenUsageAnalysisClear: (URL) throws -> Void
    private let tokenUsageScanner: (@Sendable (TokenUsageLogRoots, TimeZone, String, String, Int64) throws -> TokenUsageSnapshot)?

    init(tokenUsageStorageURL: URL? = nil, tokenUsageDefaults: UserDefaults = .standard,
         tokenUsageWrite: @escaping (Data, URL) throws -> Void = { try PrivateFile.write($0, to: $1) },
         tokenUsageAnalysisClear: @escaping (URL) throws -> Void = { try PrivateFile.write(Data(), to: $0) },
         tokenUsageScanner: (@Sendable (TokenUsageLogRoots, TimeZone, String, String, Int64) throws -> TokenUsageSnapshot)? = nil) {
        self.tokenUsageStorageURL = tokenUsageStorageURL
        self.tokenUsageDefaults = tokenUsageDefaults
        self.tokenUsageWrite = tokenUsageWrite
        self.tokenUsageAnalysisClear = tokenUsageAnalysisClear
        self.tokenUsageScanner = tokenUsageScanner
        tokenUsageEnabled = tokenUsageDefaults.bool(forKey: "ammo.tokenUsage.enabled")
        tokenUsageTimeZoneIdentifier = tokenUsageDefaults.string(forKey: "ammo.tokenUsage.timeZone") ?? TimeZone.current.identifier
    }

    @Published var message = LocalizedStatus("mac.message.initial")
    @Published var connecting = false
    @Published var connected = false
    @Published private(set) var collectionProgress: CollectorProgress?
    private static let refreshIntervalKey = "quota.collector.refreshIntervalMinutes"
    @Published private(set) var refreshInterval = CollectorRefreshInterval(
        rawValue: UserDefaults.standard.integer(forKey: MacModel.refreshIntervalKey)
    ) ?? .fiveMinutes
    @Published private(set) var providerConnections: [ProviderConnectionSummary] = []
    @Published var providerConnectionError = LocalizedStatus.empty
    var onChange: (() -> Void)?
    @Published var pairingLink = ""
    @Published var pairingOrigin = ""
    @Published var pairingFingerprint = ""
    @Published private(set) var cfSwitchBusy = false
    @Published private(set) var workerSwitchPending = false
    @Published private(set) var workerSwitchCanContinue = false
    @Published private(set) var workerSwitchCanCancel = false
    @Published private(set) var retiredServicePending = false
    @Published private(set) var retiredCleanupBusy = false
    @Published var retiredServiceMessage = LocalizedStatus.empty
    @Published private(set) var cfSyncEnabled = UserDefaults.standard.object(forKey: SyncPreferenceKeys.cloudflare) as? Bool ?? false
    @Published private(set) var iCloudEnabled = UserDefaults.standard.bool(forKey: SyncPreferenceKeys.iCloud)
    @Published private(set) var iCloudMessage = LocalizedStatus("mac.icloud.disabled")
    @Published private(set) var islandProviders = IslandProviderSelection(stored: UserDefaults.standard.stringArray(forKey: IslandProviderSelection.preferenceKey))
    @Published private(set) var mcpEnabled = UserDefaults.standard.bool(forKey: "quota.mcp.consent")
    @Published private(set) var mcpPending = UserDefaults.standard.bool(forKey: "quota.mcp.pending")
    @Published private(set) var mcpBusy = false
    @Published private(set) var mcpMessage = LocalizedStatus("mac.mcp.disabled")
    @Published private(set) var mcpEndpoint = ""
    private var mcpClient: RemoteMCPClient?
    private var iCloudSync: ICloudSnapshotSync?
    private var iCloudUpload: Task<Void, Never>?
    private var pendingICloudSnapshot: Snapshot?
    var islandWindows: [QuotaWindow] { islandProviders.filter(snapshot?.windows ?? []) }
    var availableIslandProviders: [String] {
        Array(Set((snapshot?.windows.map(\.providerId) ?? []) + providerConnections.map(\.providerID))).sorted()
    }
    func setRefreshInterval(_ value: CollectorRefreshInterval) {
        refreshInterval = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.refreshIntervalKey)
        Task { await collector?.setRefreshInterval(refreshInterval) }
    }

    func setIslandProvider(_ id: String, visible: Bool) {
        islandProviders.set(id, visible: visible, available: availableIslandProviders)
        UserDefaults.standard.set(islandProviders.selected.map { Array($0).sorted() }, forKey: IslandProviderSelection.preferenceKey)
        onChange?()
    }

    func setICloudEnabled(_ enabled: Bool) {
        iCloudEnabled = enabled
        if !enabled { pendingICloudSnapshot = nil; iCloudUpload?.cancel() }
        UserDefaults.standard.set(enabled, forKey: SyncPreferenceKeys.iCloud)
        iCloudMessage = LocalizedStatus(enabled ? "mac.icloud.waitingUpload" : "mac.icloud.stoppedUpload")
        if enabled, let snapshot { uploadICloud(snapshot) }
    }
    private func uploadICloud(_ value: Snapshot) {
        guard iCloudEnabled else { return }
        // Command-line SwiftPM builds have no CloudKit entitlement and must not call CKContainer.
        guard ICloudSnapshotSync.hasMacCloudKitEntitlement else {
            iCloudMessage = LocalizedStatus("mac.icloud.needsEntitlement"); return
        }
        if iCloudSync == nil { iCloudSync = ICloudSnapshotSync() }
        guard let service = iCloudSync else { return }
        pendingICloudSnapshot = value
        guard iCloudUpload == nil else { return }
        iCloudUpload = Task {
            defer {
                iCloudUpload = nil
                if iCloudEnabled, let pending = pendingICloudSnapshot { uploadICloud(pending) }
            }
            while iCloudEnabled, !Task.isCancelled, let next = pendingICloudSnapshot {
                pendingICloudSnapshot = nil
                do {
                    try await service.upload(next)
                    if iCloudEnabled && !Task.isCancelled { iCloudMessage = LocalizedStatus("mac.icloud.received") }
                } catch {
                    if iCloudEnabled && !Task.isCancelled { iCloudMessage = ICloudSyncFeedback.message(for: error) }
                }
            }
        }
    }
    func retryICloud() { if let snapshot { uploadICloud(snapshot) } }
    func setCFSyncEnabled(_ enabled: Bool) {
        guard !mcpBusy, !cfSwitchBusy, !cloudConnecting, !workerSwitchPending else { return }
        cfSwitchBusy = true
        Task {
            defer { cfSwitchBusy = false }
            if !enabled, shareWriter != nil {
                do { try await revokeAllShares() }
                catch { message = LocalizedStatus("mac.share.disconnectBlocked"); return }
            }
            if !enabled && (mcpEnabled || mcpPending) {
                await setMCPEnabled(false)
                guard !mcpEnabled && !mcpPending else { return }
            }
            cfSyncEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: SyncPreferenceKeys.cloudflare)
            await writer?.setSyncEnabled(enabled)
            await projectionClient?.setConsent(enabled && projectionEnabled && !rotationPending)
            if enabled, let snapshot { syncCompletedPass(snapshot) }
            if enabled { await uploadTokenUsage() }
        }
    }
    private func configureMCP(_ credentials: WriterCredentials) async throws {
        await mcpClient?.pause()
        mcpClient = try RemoteMCPClient(credentials: credentials)
        mcpEndpoint = credentials.endpoint.appendingPathComponent("mcp").absoluteString
        if mcpPending { mcpMessage = LocalizedStatus("mac.mcp.pending.retryRevoke") }
        if mcpEnabled && cfSyncEnabled && !mcpPending && !workerSwitchPending { await mcpClient?.resumeConsent(); mcpMessage = LocalizedStatus("mac.mcp.enabled.awaiting") }
    }
    func setMCPEnabled(_ enabled: Bool) async {
        guard !mcpBusy, !cloudConnecting, !workerSwitchPending, let mcpClient, !rotationPending, !rotationBusy else { return }
        mcpBusy = true
        defer { mcpBusy = false }
        do {
            if enabled {
                guard cfSyncEnabled else { return }
                let token = Base64URL.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
                try vault.save(Data(token.utf8), account: "mcp-token-draft")
                mcpPending = true
                UserDefaults.standard.set(true, forKey: "quota.mcp.pending")
                try await mcpClient.enable(token: token)
                try vault.save(Data(token.utf8), account: "mcp-read-token")
                try? vault.remove("mcp-token-draft")
                mcpPending = false
                UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
                mcpEnabled = true
                UserDefaults.standard.set(true, forKey: "quota.mcp.consent")
                mcpMessage = LocalizedStatus("mac.mcp.enabled")
                if let snapshot { try await mcpClient.upload(snapshot) }
            } else {
                try await mcpClient.disable()
                mcpEnabled = false
                UserDefaults.standard.set(false, forKey: "quota.mcp.consent")
                mcpPending = false
                UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
                try? vault.remove("mcp-token-draft")
                try? vault.remove("mcp-read-token")
                mcpMessage = LocalizedStatus("mac.mcp.revoked")
            }
        } catch {
            mcpMessage = LocalizedStatus(enabled ? "mac.mcp.enable.incomplete" : "mac.mcp.revoke.unconfirmed")
        }
    }
    @discardableResult func copyMCPEndpoint() -> Bool {
        guard mcpEnabled, !mcpPending, !mcpEndpoint.isEmpty else { return false }
        copyToPasteboard(mcpEndpoint)
        mcpMessage = LocalizedStatus("mac.mcp.endpointCopied")
        return true
    }
    @discardableResult func copyMCPToken() -> Bool {
        guard mcpEnabled, !mcpPending, let token = mcpReadToken else { return false }
        copyToPasteboard(token)
        mcpMessage = LocalizedStatus("mac.mcp.tokenCopied")
        return true
    }
    /// Ready-to-paste remote MCP client config; endpoint and token are percent-encoded
    /// URL text and base64url, so neither needs JSON escaping.
    @discardableResult func copyMCPClientConfig() -> Bool {
        guard mcpEnabled, !mcpPending, let token = mcpReadToken else { return false }
        let config = """
        {
          "mcpServers": {
            "quota-island": {
              "url": "\(mcpEndpoint)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
        copyToPasteboard(config)
        mcpMessage = LocalizedStatus("mac.mcp.configCopied")
        return true
    }
    private var mcpReadToken: String? {
        guard let data = try? vault.load("mcp-read-token") else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    @Published var cloudConnected = false
    /// Endpoint of the connected sync service; nil while no writer exists.
    /// Drives the official/self-hosted label in the pairing card.
    @Published private(set) var syncEndpoint: URL?
    var syncServiceIsOfficial: Bool? { syncEndpoint.map { SyncServiceCatalog.isOfficial($0) } }
    @Published var cloudConnecting = false
    /// Result of the last sync connect/switch attempt. Scoped to the sync
    /// form so unrelated global status lines never appear under its button.
    @Published var syncMessage = LocalizedStatus.empty
    @Published private(set) var projectionEnabled = UserDefaults.standard.bool(forKey: "quota.projectionConsent")
    @Published private(set) var projectionBusy = false
    @Published private(set) var liveUpdateMessage = LocalizedStatus("mac.live.disabled")
    private var projectionClient: LiveProjectionClient?
    private var projectionGeneration = UUID()
    @Published var rotationPending = false
    @Published var rotationBusy = false
    private var invitation: PairingInvitation?
    @Published private(set) var shares: [ShareRecord] = []
    @Published private(set) var shareInviteLink = ""
    @Published private(set) var shareInvitationID: String?
    @Published private(set) var shareBusy = false
    @Published var shareMessage = LocalizedStatus.empty
    private var shareWriter: ShareWriter?
    private var shareGeneration = UUID()
    @Published private(set) var receivedClaims: [ShareClaim] = []
    @Published private(set) var receivedGrants: [ShareGrant] = []
    @Published private(set) var receivedProjections: [String: ShareProjection] = [:]
    @Published private(set) var receivingBusy = false
    @Published var receivingMessage = LocalizedStatus.empty
    private var writer: SyncWriter?
    private var pairingBusy = false
    private let vault = KeychainVault()
    private let legacyProviderSecretCleanup = LegacyProviderSecretCleanup()
    private let providerVault = ProviderInstanceVault()
    private var instanceRoot: URL { directory.appendingPathComponent("instances", isDirectory: true) }
    private var connectionConfiguration: ProviderConnectionsConfiguration?
    private var collector: Collector?
    private var githubReadState = GitHubPartialReadState()
    private var githubExpenseObservations: [String: GitHubExpenseObservation] = [:]
    private var unavailableConnections = Set<String>()
    private let ipc = RefreshServer()
    private var sleeping = false
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaIsland")
    private var connectionFile: URL { directory.appendingPathComponent("connection.json") }
    func restore() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        ResetReminderStartupPolicy.restoreAccountIntent(coordinator: resetReminders) {
            let data = try PrivateFile.read(connectionFile, maxBytes: 65_536)
            let configuration = try ProviderConnectionsConfiguration.decodeMigrating(data).configuration
            return Set(configuration.connections.filter(\.isEnabled).map {
                ResetReminderPolicy.accountKey(providerID: $0.providerID, accountID: $0.accountID)
            })
        }
        restoreTokenUsage()
        var recoveredInitialWriter = false
        workerSwitchPending = (try? vault.load("switch-target")) != nil ||
            ((try? SyncWriter.pendingReplacementBootstrap(vault: vault)) ?? nil) != nil
        workerSwitchCanContinue = (try? vault.load("switch-target")) != nil
        workerSwitchCanCancel = (try? SyncWriter.canCancelPendingReplacementBootstrap(vault: vault)) ?? false
        retiredServicePending = ((try? RetiredServiceRevocation.pending(vault: vault)) ?? nil) != nil
        if retiredServicePending { retiredServiceMessage = LocalizedStatus("mac.worker.retired.pending") }
        if !workerSwitchPending {
            cloudConnecting = true
            do {
                if try await SyncWriter.recoverInitialBootstrap(vault: vault) != nil {
                    cfSyncEnabled = true
                    UserDefaults.standard.set(true, forKey: SyncPreferenceKeys.cloudflare)
                    projectionEnabled = false
                    UserDefaults.standard.set(false, forKey: "quota.projectionConsent")
                    recoveredInitialWriter = true
                }
            } catch { syncMessage = LocalizedStatus("mac.worker.connect.failed.config") }
            cloudConnecting = false
        }
        if let data = try? vault.load("writer"), let credentials = try? JSONDecoder().decode(WriterCredentials.self, from: data) {
            syncEndpoint = credentials.endpoint
            if UserDefaults.standard.object(forKey: SyncPreferenceKeys.cloudflare) == nil {
                cfSyncEnabled = true // Preserve previously authorized sync on upgrade.
                UserDefaults.standard.set(true, forKey: SyncPreferenceKeys.cloudflare)
            }
            rotationPending = (try? vault.load("rotation-draft")) != nil
            if !rotationPending { writer = try? SyncWriter(credentials: credentials, directory: directory.appendingPathComponent("sync")) }
            cloudConnected = rotationPending || writer != nil
            if writer != nil {
                await writer?.setSyncEnabled(cfSyncEnabled)
                await configureProjection(credentials)
                try? await configureMCP(credentials)
                shareWriter = try? ShareWriter(credentials: credentials)
            }
        }
        if recoveredInitialWriter {
            syncMessage = LocalizedStatus(cloudConnected ? "mac.worker.connected" : "mac.worker.connect.failed.config")
        }
        if workerSwitchPending && !rotationPending {
            do { try await resumePendingWorkerSwitch() }
            catch { syncMessage = LocalizedStatus("mac.worker.switch.pending") }
            workerSwitchCanContinue = (try? vault.contains("switch-target")) ?? false
            workerSwitchCanCancel = (try? SyncWriter.canCancelPendingReplacementBootstrap(vault: vault)) ?? false
        } else if workerSwitchPending {
            // Two independent identity transitions must never run together.
            syncMessage = LocalizedStatus("mac.worker.switch.pending")
        }
        let received = (try? JSONDecoder().decode(StoredReceivedShares.self, from: vault.load("received-shares")))
            ?? StoredReceivedShares(claims: [], grants: [])
        receivedClaims = received.claims
        receivedGrants = received.grants
        Task { await refreshReceivedShares() }
        snapshot = try? AtomicSnapshotReader(directory: directory).latest(); onChange?()
        if iCloudEnabled, let snapshot { uploadICloud(snapshot) }
        do {
            let data = try PrivateFile.read(connectionFile, maxBytes: 65_536)
            let decoded = try ProviderConnectionsConfiguration.decodeMigrating(data)
            var restored = decoded.configuration
            if decoded.migrated { try persist(restored) }
            if let pending = restored.pendingLegacyCredentialRemovals, !pending.isEmpty {
                let remaining = pending.filter { reference in
                    do {
                        try legacyProviderSecretCleanup.remove(reference: reference)
                        return false
                    } catch {
                        return true
                    }
                }
                if remaining != pending {
                    restored = try ProviderConnectionsConfiguration(
                        deviceID: restored.deviceID,
                        epoch: restored.epoch,
                        connections: restored.connections,
                        pendingLegacyCredentialRemovals: remaining.isEmpty ? nil : remaining,
                        pendingInstanceRemovals: restored.pendingInstanceRemovals).validated()
                    try persist(restored)
                }
                if !remaining.isEmpty {
                    message = LocalizedStatus("mac.connection.legacyCleanupPending")
                }
            }
            restored = cleanupInstances(restored)
            // Persisted connection intent wins over surviving OS requests after
            // an interrupted pause/remove, before any cached-snapshot recovery.
            resetReminders.updateAllowedAccounts(Set(restored.connections.filter(\.isEnabled).map {
                ResetReminderPolicy.accountKey(providerID: $0.providerID, accountID: $0.accountID)
            }))
            await resetReminders.reconcile(snapshot: snapshot, verified: false)
            restored = await recoverAmbientLogins(restored)
            connectionConfiguration = restored
            updateConnectionSummaries(restored)
            // Server-side grants are reconciled after configuration has loaded.
            try await activate(restored)
        } catch StoreError.unavailable {
            resetReminders.updateAllowedAccounts([]) // No configured accounts.
            await resetReminders.reconcile(snapshot: snapshot, verified: false)
        }
        catch {
            message = LocalizedStatus("mac.restore.needsReauth")
            await resetReminders.reconcile(snapshot: snapshot, verified: false)
        }
        Task { await refreshShares() }
    }
    func selectCodex() {
        Task { await presentCodexSelection() }
    }
    private func presentCodexSelection() async {
        guard !connecting else { return }
        let alert = NSAlert()
        let detected = await Task.detached(priority: .userInitiated) { CodexAppDiscovery.installedApp() }.value
        guard !connecting else { return }
        alert.messageText = L("mac.codex.connectTitle")
        alert.informativeText = L("mac.codex.connectIntro") + (detected.map { L("mac.codex.foundDetail", $0.path) } ?? L("mac.codex.chooseExecutable"))
        alert.addButton(withTitle: detected == nil ? L("mac.codex.chooseAndConnect") : L("mac.codex.connectInstalled")); alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url: URL
        if let detected { url = detected }
        else {
            let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let selected = picker.url else { return }; url = selected
        }
        Task {
            await connectProvider(providerID: "codex", alias: "Codex",
                                  executableURL: url)
        }
    }

    /// Connects (or reconnects) the machine's own CLI login for a provider.
    /// The CLI/local login owns authorization; gh supplies read-only API results.
    func connectAmbientLogin(providerID rawProviderID: String, alias rawAlias: String,
                             replacingConnectionID: String? = nil, organizationID: String? = nil) async {
        guard !connecting, !shareBusy else { return }
        connecting = true
        defer { connecting = false }
        providerConnectionError = LocalizedStatus.empty
        let previous = connectionConfiguration ?? defaultConfiguration()
        let previousUnavailableGitHubAccounts = githubReadState.unavailableExpenses
        await pauseCollector()
        var acceptanceAttempted = false
        do {
            let providerID = rawProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let record: ProviderConnectionRecord
            if let replacingConnectionID {
                guard previous.connections.contains(where: { $0.id == replacingConnectionID && $0.providerID == providerID }) else { throw ProviderFailure.parseChanged }
            }
            switch providerID {
            case "github-actions":
                let alias = trimmed.isEmpty ? "GitHub Actions" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let organization = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let scope = organization.flatMap { $0.isEmpty ? nil : $0 }
                let probe = try await GitHubCLIProvider.probe(alias: alias, organization: scope)
                rememberGitHubProbe(probe)
                record = ProviderConnectionRecord(
                    id: "local-github-" + String(probe.identityFingerprint.prefix(24)), kind: .githubCLILogin,
                    providerID: providerID, accountID: probe.accountID, accountAlias: alias,
                    expectedIdentity: probe.identityFingerprint, organizationID: scope)
            case "codex":
                let alias = trimmed.isEmpty ? "Codex" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let probe = try await CodexLocalProvider.probe(alias: alias)
                record = ProviderConnectionRecord(
                    id: "local-codex-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .codexLocalLogin, providerID: "codex", accountID: probe.accountID,
                    accountAlias: alias, expectedIdentity: probe.identityFingerprint)
            case "grok":
                let alias = trimmed.isEmpty ? "Grok" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let probe = try await GrokLocalProvider.probe(alias: alias)
                record = ProviderConnectionRecord(
                    id: "local-grok-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .grokLocalLogin, providerID: "grok", accountID: probe.accountID,
                    accountAlias: alias, expectedIdentity: probe.identityFingerprint)
            case "claude":
                let alias = trimmed.isEmpty ? "Claude" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let probe = try await ClaudeLocalProvider.probe(alias: alias)
                record = ProviderConnectionRecord(
                    id: "local-claude-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .claudeLocalLogin, providerID: "claude", accountID: probe.accountID,
                    accountAlias: alias, expectedIdentity: probe.identityFingerprint)
            case "workbuddy":
                let alias = trimmed.isEmpty ? "WorkBuddy" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let probe = try await WorkBuddyLocalProvider.probe(alias: alias)
                record = ProviderConnectionRecord(
                    id: "local-workbuddy-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .workbuddyLocalLogin, providerID: "workbuddy", accountID: probe.accountID,
                    accountAlias: alias, expectedIdentity: probe.identityFingerprint)
            case "zcode":
                let alias = trimmed.isEmpty ? "ZCode" : trimmed
                guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
                let probe = try await ZCodeLocalProvider.probe(alias: alias)
                record = ProviderConnectionRecord(
                    id: "local-zcode-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .zcodeLocalLogin, providerID: "zcode", accountID: probe.accountID,
                    accountAlias: alias, expectedIdentity: probe.identityFingerprint)
            default:
                throw ProviderFailure.unsupported
            }
            try Task.checkCancellation()
            let validated = try record.validated()
            let next = try AmbientConnectionAcceptance.prepared(previous: previous, record: validated,
                                                               replacingID: replacingConnectionID)
            let replaced = previous.connections.filter { $0.id == validated.id || $0.id == replacingConnectionID }
            do { try await revokeShares(for: replaced) }
            catch { throw ShareRevocationFailure() }
            acceptanceAttempted = true
            _ = try await AmbientConnectionAcceptance.commit(previous: previous, next: next,
                persist: { try self.persist($0) },
                install: { self.connectionConfiguration = $0; self.updateConnectionSummaries($0) },
                activate: { try await self.activate($0) }, pause: { await self.pauseCollector() },
                cleanup: { self.cleanupInstances($0) })
            message = LocalizedStatus("mac.connect.nativeDone", validated.accountAlias)
            await publishGitHubInvalidation()
        } catch {
            githubReadState.unavailableExpenses = previousUnavailableGitHubAccounts
            providerConnectionError = error is AmbientConnectionAcceptance.RecoveryFailure
                ? LocalizedStatus("mac.connection.recoveryFailed") : error is ShareRevocationFailure
                ? LocalizedStatus("mac.share.reconnectBlocked")
                : (rawProviderID == "github-actions" ? GitHubBillingReader.errorStatus(error) : connectionErrorText(error))
            message = providerConnectionError
            if !acceptanceAttempted {
                let recovered = await Task { @MainActor in
                    do { try await self.activate(previous); self.updateConnectionSummaries(previous); return true }
                    catch { return false }
                }.value
                if !recovered { providerConnectionError = LocalizedStatus("mac.connection.recoveryFailed"); message = providerConnectionError }
            }
            await Task { @MainActor in await self.publishGitHubInvalidation() }.value
        }
    }

    func connectProvider(providerID rawProviderID: String, alias rawAlias: String,
                         executableURL: URL? = nil, credential: NativeProviderCredential? = nil,
                         replacingConnectionID: String? = nil) async {
        guard !connecting, !shareBusy else { return }
        connecting = true
        defer { connecting = false }
        providerConnectionError = LocalizedStatus.empty
        let previous = connectionConfiguration ?? defaultConfiguration()
        let instanceID = UUID().uuidString
        let previousUnavailableGitHubAccounts = githubReadState.unavailableExpenses
        var rollback = previous
        rollback.pendingInstanceRemovals = (previous.pendingInstanceRemovals ?? []) + [instanceID]
        await pauseCollector()
        var probeLease: CollectorLease?
        var draftPersisted = false
        do {
            try Task.checkCancellation()
            let providerID = rawProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replacingConnectionID {
                guard previous.connections.contains(where: { $0.id == replacingConnectionID && $0.providerID == providerID })
                else { throw ProviderFailure.parseChanged }
            }
            // Record ownership before creating any credential or profile. Crash recovery can then remove drafts.
            try persist(rollback)
            draftPersisted = true
            probeLease = try CollectorLease(directory: directory)
            let record: ProviderConnectionRecord
            if providerID == "codex" {
                record = try await codexConnectionRecord(
                    executableURL: executableURL, alias: trimmed, instanceID: instanceID)
            } else {
                record = try await apiConnectionRecord(
                    providerID: providerID, alias: trimmed, credential: credential, instanceID: instanceID)
            }
            _ = probeLease
            probeLease = nil
            try Task.checkCancellation()
            let replaced = previous.connections.filter { $0.id == record.id || $0.id == replacingConnectionID }
            var next = previous
            next.connections.removeAll { $0.id == record.id || $0.id == replacingConnectionID }
            do { try await revokeShares(for: replaced) }
            catch { throw ShareRevocationFailure() }
            next.connections.append(try record.validated())
            next.pendingInstanceRemovals = (previous.pendingInstanceRemovals ?? []) + replaced.compactMap(\.instanceID)
            try persist(next)
            connectionConfiguration = next
            try await activate(next)
            try Task.checkCancellation()
            // Destruction only follows durable acceptance; nothing after this point rolls back to old credentials.
            next = cleanupInstances(next)
            connectionConfiguration = next
            updateConnectionSummaries(next)
            message = LocalizedStatus("mac.connect.nativeDone", record.accountAlias)
            await publishGitHubInvalidation()
        } catch {
            githubReadState.unavailableExpenses = previousUnavailableGitHubAccounts
            probeLease = nil
            let failure = error
            let recoveryError: LocalizedStatus? = await Task {
                await self.pauseCollector()
                do {
                    if draftPersisted { try self.persist(rollback) }
                    let restored = draftPersisted ? self.cleanupInstances(rollback) : previous
                    self.connectionConfiguration = restored
                    self.updateConnectionSummaries(restored)
                    try await self.activate(restored)
                    await self.publishGitHubInvalidation()
                    return nil
                } catch {
                    return LocalizedStatus("mac.connection.recoveryFailed")
                }
            }.value
            if let recoveryError {
                providerConnectionError = recoveryError
                message = recoveryError
            } else if Task.isCancelled {
                message = LocalizedStatus("mac.connect.cancelled")
            } else {
                if rawProviderID.trimmingCharacters(in: .whitespacesAndNewlines) == "github-actions",
                   failure is ProviderFailure {
                    providerConnectionError = GitHubBillingReader.errorStatus(failure)
                } else {
                    providerConnectionError = failure is ShareRevocationFailure
                        ? LocalizedStatus("mac.share.reconnectBlocked") : connectionErrorText(failure)
                }
                message = providerConnectionError
            }
        }
    }

    private func codexConnectionRecord(
        executableURL: URL?, alias rawAlias: String, instanceID: String) async throws -> ProviderConnectionRecord {
        guard let executableURL else { throw ProviderFailure.unsupported }
        let alias = rawAlias.isEmpty ? "Codex" : rawAlias
        guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
        let executable = try await Task.detached(priority: .userInitiated) {
            guard CodexAppDiscovery.isNativeMachO(executableURL), CodexAppDiscovery.isOpenAISigned(executableURL) else {
                throw ProviderFailure.unsupported
            }
            return try ApprovedExecutable(userSelectedURL: executableURL)
        }.value
        let profile = try CodexInstanceProfile(root: instanceRoot, id: instanceID)
        try profile.prepare()
        let result = try await BoundedRPC.login(executable: executable.verifiedURL(),
            arguments: CodexInstanceProfile.appServerArguments, environment: try profile.environment(),
            onAuthorizationURL: { url in
                Task { @MainActor in _ = NSWorkspace.shared.open(url) }
            })
        let accountID = "account-" + String(result.identityFingerprint.prefix(16))
        _ = try CodexNormalizer.normalize(result.limits, accountID: accountID, alias: alias, now: Date())
        return ProviderConnectionRecord(
            id: "native-codex-" + String(result.identityFingerprint.prefix(24)), kind: .nativeCodex,
            executable: executable, providerID: "codex", accountID: accountID, accountAlias: alias,
            expectedIdentity: result.identityFingerprint, instanceID: instanceID)
    }

    /// Legacy manual organization scope stays in Ammo's own credential vault;
    /// CLI records use only local metadata, never gh's credential store.
    func githubReconnectScope(connectionID: String?) -> GitHubReconnectScope {
        let record = connectionConfiguration?.connections.first { $0.id == connectionID }
        return GitHubReconnectScope.resolve(record: record) {
            guard let record, let reference = record.instanceID else { throw ProviderFailure.authRequired }
            return try providerVault.load(providerID: record.providerID, reference: reference).organizationID
        }
    }

    /// Rich billing details remain local and are exposed only for the saved,
    /// enabled instance after its reported identity matches the connection.
    func githubBillingDetails(connectionID: String) async throws -> GitHubBillingReport {
        guard !connecting, !shareBusy,
              let record = connectionConfiguration?.connections.first(where: { $0.id == connectionID }),
              record.providerID == "github-actions", (record.kind == .nativeProvider || record.kind == .githubCLILogin),
              record.isEnabled else { throw ProviderFailure.authRequired }
        let report: GitHubBillingReport
        if record.kind == .githubCLILogin {
            report = try await GitHubCLIProvider(accountID: record.accountID, alias: record.accountAlias,
                expectedIdentity: record.expectedIdentity, organization: record.organizationID).report()
        } else {
            guard let instanceID = record.instanceID else { throw ProviderFailure.authRequired }
            let credential = try providerVault.load(providerID: record.providerID, reference: instanceID)
            report = try await GitHubBillingReader.report(credential)
        }
        try Task.checkCancellation()
        let normalized = try GitHubBillingReader.normalized(report, alias: record.accountAlias)
        guard normalized.identityFingerprint == record.expectedIdentity, normalized.accountID == record.accountID,
              !connecting, !shareBusy,
              let current = connectionConfiguration?.connections.first(where: { $0.id == connectionID }),
              current.providerID == record.providerID, current.kind == record.kind, current.isEnabled,
              current.instanceID == record.instanceID, current.organizationID == record.organizationID, current.expectedIdentity == record.expectedIdentity,
              current.accountID == record.accountID else { throw ProviderFailure.authRequired }
        rememberGitHubProbe(.init(accountID: normalized.accountID, identityFingerprint: normalized.identityFingerprint,
                                  windows: normalized.windows, retryNotBefore: normalized.retryNotBefore, expenseObservedAt: normalized.expenseObservedAt))
        await publishGitHubInvalidation()
        return report
    }

    private func apiConnectionRecord(
        providerID: String, alias rawAlias: String,
        credential: NativeProviderCredential?, instanceID: String) async throws -> ProviderConnectionRecord {
        guard let descriptor = NativeProviderCatalog.descriptor(for: providerID),
              NativeProviderCatalog.apiProviderIDs.contains(providerID), let credential else {
            throw ProviderFailure.unsupported
        }
        let alias = rawAlias.isEmpty ? descriptor.displayName : rawAlias
        guard alias.count <= 48 else { throw ProviderFailure.parseChanged }
        try credential.validated()
        try providerVault.save(credential, providerID: providerID, reference: instanceID)
        let probe = try await NativeProvider.probe(providerID: providerID, alias: alias, credential: credential)
        if providerID == "github-actions" { rememberGitHubProbe(probe) }
        let record = ProviderConnectionRecord(
            id: "native-" + String(probe.identityFingerprint.prefix(32)), kind: .nativeProvider,
            providerID: providerID, accountID: probe.accountID, accountAlias: alias,
            expectedIdentity: probe.identityFingerprint, instanceID: instanceID,
            organizationID: providerID == "github-actions" ? credential.organizationID : nil)
        let retainedCount = snapshot?.windows.filter {
            $0.providerId != record.providerID || $0.accountId != record.accountID
        }.count ?? 0
        guard retainedCount + probe.windows.count <= SnapshotCodec.maxWindows else {
            throw WindowBudgetExceeded(proposed: retainedCount + probe.windows.count, cap: SnapshotCodec.maxWindows)
        }
        return record
    }

    /// Best-effort deletion, with durable retry references for locked or missing profiles.
    private func cleanupInstances(_ configuration: ProviderConnectionsConfiguration) -> ProviderConnectionsConfiguration {
        AmbientConnectionAcceptance.cleanup(configuration,
            persist: { try self.persist($0) },
            removeCredential: { try self.providerVault.remove(reference: $0) },
            removeProfile: { try CodexInstanceProfile(root: self.instanceRoot, id: $0).remove() })
    }

    func setConnectionEnabled(id: String, enabled: Bool) async {
        guard !connecting, !shareBusy, let current = connectionConfiguration,
              let index = current.connections.firstIndex(where: { $0.id == id }),
              current.connections[index].isEnabled != enabled else { return }
        if enabled, current.connections[index].instanceID == nil,
           !current.connections[index].kind.usesLocalLogin {
            providerConnectionError = LocalizedStatus("mac.connection.reconnectStandaloneFirst")
            return
        }
        connecting = true
        defer { connecting = false }
        if !enabled {
            do { try await revokeShares(for: [current.connections[index]]) }
            catch { providerConnectionError = LocalizedStatus("mac.share.pauseBlocked"); return }
        }
        providerConnectionError = LocalizedStatus.empty
        await pauseCollector()
        do {
            var next = current
            next.connections[index].isEnabled = enabled
            try persist(next)
            connectionConfiguration = next
            updateConnectionSummaries(next)
            try await activate(next)
            message = LocalizedStatus(enabled ? "mac.connection.resumed" : "mac.connection.paused")
            await publishGitHubInvalidation()
        } catch {
            await pauseCollector()
            do {
                try persist(current)
                connectionConfiguration = current
                updateConnectionSummaries(current)
                try await activate(current)
                await publishGitHubInvalidation()
                providerConnectionError = LocalizedStatus("mac.connection.toggleSaveFailed")
            } catch {
                providerConnectionError = LocalizedStatus("mac.connection.recoveryFailed")
            }
        }
    }

    func removeConnection(id: String) async {
        guard !connecting, !shareBusy, let current = connectionConfiguration,
              let removed = current.connections.first(where: { $0.id == id }) else { return }
        connecting = true
        defer { connecting = false }
        do { try await revokeShares(for: [removed]) }
        catch { providerConnectionError = LocalizedStatus("mac.share.removeBlocked"); return }
        providerConnectionError = LocalizedStatus.empty
        await pauseCollector()
        do {
            let next = try ProviderConnectionsConfiguration(
                deviceID: current.deviceID, epoch: current.epoch,
                connections: current.connections.filter { $0.id != id },
                pendingLegacyCredentialRemovals: current.pendingLegacyCredentialRemovals,
                pendingInstanceRemovals: (current.pendingInstanceRemovals ?? []) + [removed.instanceID].compactMap { $0 }).validated()
            try persist(next)
            connectionConfiguration = next
            updateConnectionSummaries(next)
            try await activate(next)
            let cleaned = cleanupInstances(next)
            connectionConfiguration = cleaned
            message = LocalizedStatus(
                (cleaned.pendingInstanceRemovals ?? []).contains(removed.instanceID ?? "")
                    ? "mac.remove.cleanupPending" : "mac.remove.done",
                removed.accountAlias)
            await publishGitHubInvalidation()
        } catch {
            await pauseCollector()
            do {
                // rename may have succeeded even when the directory fsync throws.
                try persist(current)
                connectionConfiguration = current
                updateConnectionSummaries(current)
                try await activate(current)
                await publishGitHubInvalidation()
                providerConnectionError = LocalizedStatus("mac.connection.removeFailed")
            } catch {
                providerConnectionError = LocalizedStatus("mac.connection.recoveryFailed")
            }
            message = providerConnectionError
        }
    }

    private func rememberGitHubProbe(_ probe: NativeProviderProbeResult) { githubReadState.observe(probe) }

    private func publishGitHubInvalidation() async {
        guard let target = collector else { return } // Keep markers for accepted replacement.
        do {
            let applied = try await target.publishRetainedGitHubInvalidation(failures: githubReadState.unavailableExpenses)
            if !applied, let current = collector, current !== target {
                try await current.publishRetainedGitHubInvalidation(failures: githubReadState.unavailableExpenses)
            }
        } catch { message = connectionErrorText(error) }
    }

    private func activate(_ config: ProviderConnectionsConfiguration) async throws {
        if !config.connections.contains(where: \.isEnabled) {
            connected = false
            collector = nil
            return
        }
        let store = try SnapshotStore(directory: directory)
        var providers: [any QuotaProvider] = []
        var invalidCount = 0
        unavailableConnections = []
        for record in config.connections {
            do { providers.append(try await runtimeProvider(record)) }
            catch { invalidCount += 1; unavailableConnections.insert(record.id) }
        }
        guard !providers.isEmpty else {
            connected = false
            collector = nil
            message = LocalizedStatus("mac.activate.allNeedReauth")
            updateConnectionSummaries(config)
            return
        }
        let collector = try Collector(store: store, directory: directory, providers: providers,
                                      deviceID: config.deviceID, epoch: config.epoch,
                                      retryNotBefore: githubReadState.retryDeadlines,
                                      githubExpenseObservations: githubExpenseObservations,
                                      onSnapshot: { [weak self] snapshot in
            await self?.receive(snapshot)
        }, onProgress: { [weak self] progress in
            await self?.setCollectionProgress(progress)
        }, onPassComplete: { [weak self] snapshot in
            await self?.syncCompletedPass(snapshot)
        })
        self.collector = collector
        // Keep paused accounts in the collector's retained snapshot, but disable
        // them before the scheduler can launch its first fetch.
        for record in config.connections where !record.isEnabled {
            await collector.setEnabled(false, key: record.providerID + "/" + record.accountID)
        }
        await collector.setRefreshInterval(refreshInterval)
        await collector.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        if sleeping { await collector.setSuspended(true) }
        do {
            try await collector.start()
            try await ipc.start(directory: directory) { provider in try await collector.refresh(providerID: provider) }
            connected = true
            message = invalidCount > 0 ? LocalizedStatus("mac.activate.someNeedReauth") : localStatusMessage()
            updateConnectionSummaries(config)
        } catch { await collector.stop(); self.collector = nil; throw error }
    }

    private func runtimeProvider(_ record: ProviderConnectionRecord) async throws -> any QuotaProvider {
        _ = try record.validated()
        if !record.isEnabled { return PausedConnectionProvider(record) }
        if record.kind == .githubCLILogin {
            return GitHubCLIProvider(accountID: record.accountID, alias: record.accountAlias,
                                     expectedIdentity: record.expectedIdentity, organization: record.organizationID)
        }
        if record.kind == .codexLocalLogin {
            return CodexLocalProvider(accountID: record.accountID, alias: record.accountAlias,
                                      expectedIdentity: record.expectedIdentity)
        }
        if record.kind == .grokLocalLogin {
            return GrokLocalProvider(accountID: record.accountID, alias: record.accountAlias,
                                     expectedIdentity: record.expectedIdentity)
        }
        if record.kind == .claudeLocalLogin {
            return ClaudeLocalProvider(accountID: record.accountID, alias: record.accountAlias,
                                       expectedIdentity: record.expectedIdentity)
        }
        if record.kind == .workbuddyLocalLogin {
            return WorkBuddyLocalProvider(accountID: record.accountID, alias: record.accountAlias,
                                          expectedIdentity: record.expectedIdentity)
        }
        if record.kind == .zcodeLocalLogin {
            return ZCodeLocalProvider(accountID: record.accountID, alias: record.accountAlias,
                                      expectedIdentity: record.expectedIdentity)
        }
        guard let instanceID = record.instanceID else { throw ProviderFailure.authRequired }
        switch record.kind {
        case .nativeCodex:
            guard let executable = record.executable else { throw ProviderFailure.authRequired }
            if record.isEnabled {
                _ = try await Task.detached(priority: .utility) { try executable.verifiedURL() }.value
            }
            return CodexProvider(executable: executable, accountID: record.accountID,
                                 alias: record.accountAlias, expectedIdentity: record.expectedIdentity,
                                 profile: try CodexInstanceProfile(root: instanceRoot, id: instanceID))
        case .nativeProvider:
            return try NativeProvider(providerID: record.providerID, accountID: record.accountID,
                alias: record.accountAlias, expectedIdentity: record.expectedIdentity,
                credential: try providerVault.load(providerID: record.providerID, reference: instanceID))
        case .codexLocalLogin, .grokLocalLogin, .claudeLocalLogin, .workbuddyLocalLogin, .zcodeLocalLogin, .githubCLILogin:
            throw ProviderFailure.authRequired // Handled above.
        }
    }

    private func setCollectionProgress(_ progress: CollectorProgress?) {
        collectionProgress = progress
    }

    private func pauseCollector() async {
        await collector?.stop()
        if let deadlines = await collector?.retainedRetryDeadlines() {
            for (key, date) in deadlines { githubReadState.retryDeadlines[key] = max(githubReadState.retryDeadlines[key] ?? date, date) }
        }
        if let observations = await collector?.retainedGitHubExpenseObservations() {
            for (key, proof) in observations where githubExpenseObservations[key].map({ $0.observedAt <= proof.observedAt }) ?? true {
                githubExpenseObservations[key] = proof
            }
        }
        await ipc.stop()
        collectionProgress = nil
        collector = nil
        connected = false
    }

    /// Releases before 0.1.2 carried connections bound to the machine's own
    /// CLI logins. Restore them once, without user action, whenever the ambient
    /// credential files exist and still probe as the same account.
    private func recoverAmbientLogins(_ configuration: ProviderConnectionsConfiguration) async -> ProviderConnectionsConfiguration {
        var next = configuration
        var changed = false
        if !next.connections.contains(where: { $0.kind == .codexLocalLogin }),
           FileManager.default.fileExists(atPath: CodexLocalProvider.authFile.path) {
            let probe: NativeProviderProbeResult?
            do { probe = try await CodexLocalProvider.probe(alias: "Codex") }
            catch {
                probe = nil
                // Do not persist raw probe errors; they may contain local paths.
            }
            if let probe {
                let record = ProviderConnectionRecord(
                    id: "local-codex-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .codexLocalLogin, providerID: "codex", accountID: probe.accountID,
                    accountAlias: "Codex", expectedIdentity: probe.identityFingerprint)
                if let validated = try? record.validated(),
                   !next.connections.contains(where: { $0.id == validated.id }) {
                    next.connections.append(validated)
                    changed = true
                }
            }
        }
        if !next.connections.contains(where: { $0.kind == .grokLocalLogin }),
           FileManager.default.fileExists(atPath: GrokLocalProvider.authFile.path) {
            if let probe = try? await GrokLocalProvider.probe(alias: "Grok") {
                let record = ProviderConnectionRecord(
                    id: "local-grok-" + String(probe.identityFingerprint.prefix(24)),
                    kind: .grokLocalLogin, providerID: "grok", accountID: probe.accountID,
                    accountAlias: "Grok", expectedIdentity: probe.identityFingerprint)
                if let validated = try? record.validated(),
                   !next.connections.contains(where: { $0.id == validated.id }) {
                    next.connections.append(validated)
                    changed = true
                }
            }
        }
        guard changed, let persisted = try? next.validated() else { return configuration }
        do { try persist(persisted) } catch { return configuration }
        return persisted
    }

    private func defaultConfiguration() -> ProviderConnectionsConfiguration {
        ProviderConnectionsConfiguration(
            deviceID: snapshot?.sourceDeviceId ?? "mac-" + UUID().uuidString,
            epoch: snapshot?.sourceEpoch ?? UUID().uuidString,
            connections: [])
    }

    private func persist(_ config: ProviderConnectionsConfiguration) throws {
        let validated = try config.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try ResetReminderStartupPolicy.commitAccountIntent(coordinator: resetReminders,
            accountKeys: Set(validated.connections.filter(\.isEnabled).map {
                ResetReminderPolicy.accountKey(providerID: $0.providerID, accountID: $0.accountID)
            })) {
                try PrivateFile.write(try encoder.encode(validated), to: connectionFile)
            }
    }

    private func updateConnectionSummaries(_ config: ProviderConnectionsConfiguration) {
        providerConnections = config.connections.map { record in
            let windows = snapshot?.windows.filter { $0.providerId == record.providerID && $0.accountId == record.accountID } ?? []
            let status: ConnectionStatusKind
            if record.instanceID == nil, !record.kind.usesLocalLogin {
                status = .reconnectStandalone
            } else if !record.isEnabled {
                status = .paused
            } else if unavailableConnections.contains(record.id) || windows.contains(where: { $0.fetchOutcome == .authRequired }) {
                status = .authNeedsUpdate
            } else if windows.contains(where: { $0.fetchOutcome == .throttled }) {
                status = .throttled
            } else if windows.contains(where: { $0.fetchOutcome == .error }) {
                status = .updateIncomplete
            } else {
                status = windows.isEmpty ? .waitingFirst : .bound
            }
            let method: ConnectionMethodKind
            switch record.kind {
            case .nativeCodex: method = .nativeCodex
            case .codexLocalLogin: method = .codexLocalLogin
            case .grokLocalLogin: method = .grokLocalLogin
            case .claudeLocalLogin: method = .claudeLocalLogin
            case .workbuddyLocalLogin: method = .workbuddyLocalLogin
            case .zcodeLocalLogin: method = .zcodeLocalLogin
            case .githubCLILogin: method = .githubCLILogin
            case .nativeProvider: method = .nativeProvider
            }
            return ProviderConnectionSummary(
                id: record.id, providerID: record.providerID,
                displayName: NativeProviderCatalog.descriptor(for: record.providerID)?.displayName ?? record.providerID,
                accountAlias: record.accountAlias,
                methodKind: method,
                statusKind: status, isEnabled: record.isEnabled,
                usesAmbientLogin: record.kind.usesLocalLogin, organizationID: record.organizationID)
        }
    }
    private func localStatusMessage() -> LocalizedStatus {
        LocalizedStatus(rotationPending ? "mac.localStatus.rotationPending" :
            (cfSyncEnabled ? (cloudConnected ? "mac.localStatus.cloudflareOn" : "mac.localStatus.cloudflarePending") : (iCloudEnabled ? "mac.localStatus.icloudOn" : "mac.localStatus.syncOff")))
    }

    private func connectionErrorText(_ error: Error) -> LocalizedStatus {
        if let exceeded = error as? WindowBudgetExceeded {
            return LocalizedStatus("mac.error.windowBudget", exceeded.proposed, exceeded.cap)
        }
        return switch error as? ProviderFailure {
        case .authRequired: LocalizedStatus("mac.error.authRequired")
        case .timeout: LocalizedStatus("mac.error.timeout")
        case .outputLimit: LocalizedStatus("mac.error.outputLimit")
        case .permissionDenied: LocalizedStatus("mac.error.permissionDenied")
        case .parseChanged: LocalizedStatus("mac.error.parseChanged")
        case .unsupported: LocalizedStatus("mac.error.unsupported")
        default: LocalizedStatus("mac.error.default")
        }
    }
    private func receive(_ value: Snapshot) {
        for window in value.windows where window.providerId == "github-actions" && window.availability == .available {
            let key = "github-actions/" + window.accountId
            if let failedAt = githubReadState.unavailableExpenses[key], let rawObservedAt = window.observedAt, let observedAt = QuotaRules.date(rawObservedAt), observedAt > failedAt {
                githubReadState.unavailableExpenses[key] = nil
            }
        }
        snapshot = value; billing.observe(value.windows); onChange?()
        if let configuration = connectionConfiguration {
            updateConnectionSummaries(configuration)
        }
        Task {
            guard let current = snapshot, current.sourceDeviceId == value.sourceDeviceId,
                  current.sourceEpoch == value.sourceEpoch, current.sourceSequence == value.sourceSequence,
                  current.snapshotId == value.snapshotId else { return }
            await resetReminders.reconcile(snapshot: value, verified: true)
        }
    }

    private func syncCompletedPass(_ value: Snapshot) {
        Task { await uploadTokenUsage() }
        uploadICloud(value)
        if shareWriter != nil { Task { await publishShares(value) } }
        if cfSyncEnabled, let writer { Task {
            guard cfSyncEnabled else { return }
            do { try await writer.upload(value) }
            catch { message = LocalizedStatus("mac.sync.uploadFailed") }
            await publishProjection(value)
            if cfSyncEnabled && mcpEnabled && !mcpPending && !mcpBusy && !cloudConnecting && !workerSwitchPending {
                do { try await mcpClient?.upload(value); mcpMessage = LocalizedStatus("mac.mcp.shared") }
                catch { mcpMessage = LocalizedStatus("mac.mcp.share.failed") }
            }
        } }
    }

    private func configureProjection(_ credentials: WriterCredentials) async {
        await projectionClient?.setConsent(false)
        projectionGeneration = UUID()
        projectionClient = try? LiveProjectionClient(credentials: credentials)
        billing.phoneRelay = try? BillingAlertRelay(credentials: credentials)
        await projectionClient?.setConsent(cfSyncEnabled && projectionEnabled && !rotationPending && !cloudConnecting && !workerSwitchPending)
        liveUpdateMessage = LocalizedStatus(projectionEnabled ? "mac.live.waitingNext" : "mac.live.disabled")
    }

    func setProjectionEnabled(_ enabled: Bool) {
        guard !projectionBusy, !rotationBusy, !rotationPending, !cloudConnecting, !workerSwitchPending else { return }
        projectionEnabled = enabled
        projectionBusy = true
        UserDefaults.standard.set(enabled, forKey: "quota.projectionConsent")
        Task {
            await projectionClient?.setConsent(cfSyncEnabled && enabled && !cloudConnecting && !workerSwitchPending)
            projectionBusy = false
            liveUpdateMessage = LocalizedStatus(enabled ? "mac.live.waitingUpload" : "mac.live.turnOff")
            if enabled, let snapshot { await publishProjection(snapshot) }
        }
    }

    private func publishProjection(_ value: Snapshot) async {
        guard cfSyncEnabled, projectionEnabled, !rotationPending, !cloudConnecting, !workerSwitchPending, let projectionClient else { return }
        let generation = projectionGeneration
        let result = await projectionClient.upload(value)
        guard cfSyncEnabled, projectionEnabled, !rotationPending, !cloudConnecting, !workerSwitchPending, generation == projectionGeneration else { return }
        if result.failed > 0 {
            liveUpdateMessage = LocalizedStatus("mac.live.partialUpload")
        } else if result.accepted > 0 {
            liveUpdateMessage = LocalizedStatus("mac.live.accepted", result.accepted)
        }
    }
    func refresh() {
        Task {
            // A foreground click proves the Mac is awake even if a wake notification
            // was missed while the process was suspended.
            sleeping = false
            await updateSuspension()
            do { try await collector?.refresh() }
            catch { message = LocalizedStatus("mac.refresh.unavailable") }
            await refreshTokenUsage()
        }
    }
    // Usage consent is separate from quota connections: logs belong to agents,
    // not to an API/account row, and are counted only once per physical Mac.
    #if DEBUG
    /// Test-only rendering seam. Does not restore accounts, scan logs, start timers,
    /// persist consent or connect any sync service. Never used by normal app launch.
    static func preview(tokenUsage: TokenUsageSnapshot) -> MacModel {
        let model = MacModel()
        model.tokenUsage = tokenUsage
        model.tokenUsageEnabled = true
        model.tokenUsageBusy = false
        model.tokenUsageMessage = nil
        model.tokenUsageTimeZoneIdentifier = tokenUsage.timeZoneIdentifier
        model.cfSyncEnabled = false
        model.iCloudEnabled = false
        return model
    }
    #endif

    private var tokenUsageFile: URL { tokenUsageStorageURL ?? directory.appendingPathComponent("token-usage.json") }
    private var tokenUsageAnalysisFile: URL { tokenUsageFile.deletingLastPathComponent().appendingPathComponent("token-usage-local-analysis.json") }
    func restoreTokenUsage(startLoop: Bool = true, now: Date = Date()) {
        tokenUsage = try? TokenUsageSnapshotCodec.decode(PrivateFile.read(tokenUsageFile, maxBytes: TokenUsageSnapshotCodec.maxBytes))
        if tokenUsageEnabled,
           let analysis = try? JSONDecoder().decode(TokenUsageLocalAnalysis.self, from: PrivateFile.read(tokenUsageAnalysisFile, maxBytes: 524_288)),
           let snapshot = tokenUsage, analysis.isValid(for: snapshot) {
            tokenUsageLocalAnalysis = analysis
        }
        let hasConsentRecord = tokenUsageDefaults.object(forKey: "ammo.tokenUsage.enabled") != nil
        let hasLocalAnalysis = FileManager.default.fileExists(atPath: tokenUsageAnalysisFile.path)
        if !tokenUsageEnabled, tokenUsage != nil || hasConsentRecord || hasLocalAnalysis { _ = persistDisabledTokenUsage(now: now) }
        if startLoop, tokenUsageEnabled || tokenUsage != nil || hasConsentRecord || hasLocalAnalysis { startTokenUsageLoop() }
    }
    /// Reconcile persisted consent before any upload, including after a crash or
    /// failed local replacement write. A failed write never exposes old aggregates.
    @discardableResult
    func persistDisabledTokenUsage(now: Date = Date()) -> Bool {
        guard !tokenUsageEnabled else { return false }
        tokenUsageLocalAnalysis = nil
        TokenUsageScanner.clearCachedAnalysis()
        // Replace derived history atomically even when the disabled observation
        // is already fresh. Failures stay visible and retry on the loop/restart;
        // they must not block syncing a successfully persisted consent tombstone.
        let analysisCleared: Bool
        do { try tokenUsageAnalysisClear(tokenUsageAnalysisFile); analysisCleared = true }
        catch { analysisCleared = false }
        // Worker ciphertext expires seven days after receipt. Renew an empty
        // disabled observation daily while the Mac runs, so saved receipts cannot
        // suppress delivery forever. Keep each observation stable between renewals.
        if let tokenUsage, tokenUsage.isDisabledObservation,
           let capturedAt = QuotaRules.date(tokenUsage.capturedAt) {
            let age = now.timeIntervalSince(capturedAt)
            if age >= 0, age < 24 * 60 * 60 {
                tokenUsageMessage = analysisCleared ? nil : L("tokenUsage.error.clearAnalysis")
                return true
            }
        }
        let zone = TimeZone(identifier: tokenUsageTimeZoneIdentifier) ?? .current
        let identity = tokenUsageIdentity()
        let disabled = TokenUsageSnapshot(sourceDeviceId: identity.device, sourceEpoch: identity.epoch,
            sourceSequence: nextTokenUsageSequence(), capturedAt: ISO8601DateFormatter().string(from: now),
            timeZoneIdentifier: zone.identifier, retainedFromDay: TokenUsageCalendar.day(now, in: zone),
            sources: TokenUsageAgent.allCases.map { TokenUsageSource(agent: $0, status: .disabled) }, buckets: [])
        do {
            try tokenUsageWrite(TokenUsageSnapshotCodec.encode(disabled), tokenUsageFile)
            tokenUsage = disabled; tokenUsageMessage = analysisCleared ? nil : L("tokenUsage.error.clearAnalysis")
            return true
        } catch {
            tokenUsage = nil; tokenUsageMessage = L("tokenUsage.error.save")
            return false
        }
    }
    private func startTokenUsageLoop() {
        tokenUsageLoop?.cancel()
        tokenUsageLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.tokenUsageEnabled { await self.refreshTokenUsage() }
                else if self.persistDisabledTokenUsage() { await self.uploadTokenUsage() } // Retry local save and sync without reading logs.
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
    func setTokenUsageEnabled(_ enabled: Bool) async {
        guard enabled != tokenUsageEnabled else { return }
        tokenUsageEnabled = enabled
        tokenUsageDefaults.set(enabled, forKey: "ammo.tokenUsage.enabled")
        let generation = UUID()
        tokenUsageGeneration = generation; tokenUsageScan?.cancel(); tokenUsageLoop?.cancel()
        if let scan = tokenUsageScan { _ = try? await scan.value }
        guard generation == tokenUsageGeneration else { return }
        tokenUsageScan = nil; tokenUsageBusy = false
        if enabled { startTokenUsageLoop() }
        else {
            // Persist/retry an empty observation even when the first write fails.
            if persistDisabledTokenUsage() { await uploadTokenUsage() }
            startTokenUsageLoop()
        }
    }
    func rescanTokenUsage(timeZoneIdentifier: String) async {
        guard TimeZone(identifier: timeZoneIdentifier) != nil, !tokenUsageBusy else { return }
        tokenUsageTimeZoneIdentifier = timeZoneIdentifier
        tokenUsageDefaults.set(timeZoneIdentifier, forKey: "ammo.tokenUsage.timeZone")
        await refreshTokenUsage()
    }
    private func tokenUsageIdentity() -> (device: String, epoch: String) {
        let defaults = tokenUsageDefaults
        let device = defaults.string(forKey: "ammo.tokenUsage.device") ?? "usage-" + UUID().uuidString
        let epoch = defaults.string(forKey: "ammo.tokenUsage.epoch") ?? UUID().uuidString
        defaults.set(device, forKey: "ammo.tokenUsage.device"); defaults.set(epoch, forKey: "ammo.tokenUsage.epoch")
        return (device, epoch)
    }
    private func nextTokenUsageSequence() -> Int64 {
        let old = max(Int64(tokenUsageDefaults.integer(forKey: "ammo.tokenUsage.sequence")), tokenUsage?.sourceSequence ?? 0)
        let next = old + 1
        tokenUsageDefaults.set(next, forKey: "ammo.tokenUsage.sequence")
        return next
    }
    func refreshTokenUsage() async {
        guard tokenUsageEnabled, !tokenUsageBusy else { return }
        tokenUsageBusy = true; tokenUsageMessage = nil
        let generation = tokenUsageGeneration
        let identity = tokenUsageIdentity(), sequence = nextTokenUsageSequence()
        let zone = TimeZone(identifier: tokenUsageTimeZoneIdentifier) ?? .current
        let roots = TokenUsageLogRoots.standard()
        let scanner = tokenUsageScanner
        let task = Task.detached(priority: .utility) {
            if let scanner {
                return TokenUsageScanResult(snapshot: try scanner(roots, zone, identity.device, identity.epoch, sequence), localAnalysis: nil)
            }
            return try TokenUsageScanner.scanWithAnalysis(roots: roots, timeZone: zone, deviceID: identity.device,
                                                          epoch: identity.epoch, sequence: sequence)
        }
        tokenUsageScan = task
        defer { if generation == tokenUsageGeneration { tokenUsageBusy = false; tokenUsageScan = nil } }
        do {
            let result = try await task.value
            let value = result.snapshot
            guard generation == tokenUsageGeneration, tokenUsageEnabled else { return }
            try tokenUsageWrite(TokenUsageSnapshotCodec.encode(value), tokenUsageFile)
            tokenUsage = value
            tokenUsageLocalAnalysis = result.localAnalysis
            if let analysis = result.localAnalysis {
                try? PrivateFile.write(JSONEncoder().encode(analysis), to: tokenUsageAnalysisFile)
            }
            await uploadTokenUsage()
        } catch is CancellationError { /* Consent revoked or app closed. */ }
        catch { if generation == tokenUsageGeneration { tokenUsageMessage = L("tokenUsage.error.scan") } }
    }
    private func uploadTokenUsage() async {
        guard cfSyncEnabled, !rotationPending, !rotationBusy, !cloudConnecting, !workerSwitchPending,
              let writer, let tokenUsage, tokenUsageEnabled || tokenUsage.isDisabledObservation else { return }
        do {
            let accepted = try await writer.uploadUsage(tokenUsage)
            tokenUsageSyncMessage = accepted ? nil : L("tokenUsage.sync.upgradeWorker")
        } catch { tokenUsageSyncMessage = L("tokenUsage.sync.macFailed") }
    }

    func tokenUsageIsStale(now: Date = Date()) -> Bool {
        guard let date = tokenUsage.flatMap({ QuotaRules.date($0.capturedAt) }) else { return true }
        let age = now.timeIntervalSince(date)
        return age < 0 || age > 15 * 60 || tokenUsageMessage != nil
    }

    func disconnectSource() {
        guard !providerConnections.isEmpty, !connecting, !shareBusy else { return }
        connecting = true
        Task {
            defer { connecting = false }
            let current = connectionConfiguration ?? defaultConfiguration()
            do { try await revokeShares(for: current.connections) }
            catch { message = LocalizedStatus("mac.share.disconnectBlocked"); return }
            await pauseCollector()
            do {
                let next = try ProviderConnectionsConfiguration(
                    deviceID: current.deviceID,
                    epoch: current.epoch,
                    connections: [],
                    pendingLegacyCredentialRemovals: current.pendingLegacyCredentialRemovals,
                    pendingInstanceRemovals: (current.pendingInstanceRemovals ?? []) + current.connections.compactMap(\.instanceID)).validated()
                try persist(next)
                connectionConfiguration = next
                updateConnectionSummaries(next)
                let cleaned = cleanupInstances(next)
                connectionConfiguration = cleaned
                message = LocalizedStatus((cleaned.pendingInstanceRemovals ?? []).isEmpty
                    ? "mac.disconnect.done" : "mac.disconnect.cleanupPending")
            } catch {
                await pauseCollector()
                do {
                    try persist(current)
                    connectionConfiguration = current
                    updateConnectionSummaries(current)
                    try await activate(current)
                    await publishGitHubInvalidation()
                    message = LocalizedStatus("mac.connection.removeFailed")
                } catch {
                    message = LocalizedStatus("mac.connection.recoveryFailed")
                }
            }
        }
    }
    func suspend(_ value: Bool) async { sleeping = value; await updateSuspension() }
    func powerStateChanged() { Task { await collector?.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled) } }
    private func updateSuspension() async { await collector?.setSuspended(sleeping) }

    func connectWorker() {
        guard writer == nil else { return }
        let endpoint = NSTextField(frame: NSRect(x: 0, y: 40, width: 360, height: 24)); endpoint.placeholderString = L("mac.worker.endpointPlaceholder")
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); token.placeholderString = L("mac.worker.tokenPlaceholder")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 70)); accessory.addSubview(endpoint); accessory.addSubview(token)
        let alert = NSAlert(); alert.messageText = L("mac.worker.connect.title")
        alert.informativeText = L("mac.worker.connect.info")
        alert.accessoryView = accessory; alert.addButton(withTitle: L("mac.worker.connect.button")); alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: endpoint.stringValue) else { return }
        let bootstrapToken = token.stringValue; token.stringValue = ""
        Task {
            await connectWorker(endpoint: url, bootstrapToken: bootstrapToken)
        }
    }
    func connectWorker(endpoint: URL, bootstrapToken: String) async {
        guard writer == nil, !connecting, !cloudConnecting, !workerSwitchPending, !rotationPending, endpoint.scheme == "https", !bootstrapToken.isEmpty else {
            syncMessage = LocalizedStatus("mac.worker.connect.failed.token")
            return
        }
        cloudConnecting = true
        defer { cloudConnecting = false }
        do {
            let credentials = try await SyncWriter.bootstrap(endpoint: endpoint, token: bootstrapToken, vault: vault)
            activate(try SyncWriter(credentials: credentials, directory: directory.appendingPathComponent("sync")), credentials: credentials)
            syncMessage = LocalizedStatus("mac.worker.connected")
        } catch { syncMessage = LocalizedStatus("mac.worker.connect.failed.config") }
    }

    /// Keep the old writer identity until the target is durable and every old
    /// plaintext grant has a confirmed remote revocation.
    func switchWorker(endpoint: URL, bootstrapToken: String) async {
        guard writer != nil, !connecting, !shareBusy, !cloudConnecting, !workerSwitchPending, !retiredServicePending, !retiredCleanupBusy,
              !rotationPending, !rotationBusy, !pairingBusy, !mcpBusy, !cfSwitchBusy,
              endpoint.scheme == "https", !bootstrapToken.isEmpty else {
            syncMessage = LocalizedStatus("mac.worker.connect.failed.token")
            return
        }
        do {
            if case .some = try RetiredServiceRevocation.pending(vault: vault) {
                retiredServicePending = true
                syncMessage = LocalizedStatus("mac.worker.retired.pending")
                return
            }
        } catch { syncMessage = LocalizedStatus("mac.worker.switch.failed"); return }
        let alert = NSAlert()
        alert.messageText = L("mac.worker.switch.title")
        alert.informativeText = L("mac.worker.switch.info", endpoint.absoluteString)
        alert.addButton(withTitle: L("mac.worker.switch.button"))
        alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cloudConnecting = true
        defer { cloudConnecting = false }
        // Freeze old share publication before any replacement workspace exists.
        workerSwitchPending = true
        shareGeneration = UUID()
        projectionGeneration = UUID()
        await projectionClient?.setConsent(false)
        await mcpClient?.pause()
        do {
            let credentials = try await SyncWriter.bootstrap(endpoint: endpoint, token: bootstrapToken, vault: vault,
                supersedingStored: true, persist: false)
            // The bootstrap draft holds the input and keys before the network
            // request; the receipt and returned identity are saved in Keychain.
            try vault.save(JSONEncoder().encode(credentials), account: "switch-target")
            workerSwitchPending = true
            workerSwitchCanContinue = true
            workerSwitchCanCancel = false
            try await resumePendingWorkerSwitch()
            syncMessage = LocalizedStatus("mac.worker.switch.done")
        } catch {
            // A protected draft can outlive an ambiguous network failure or a
            // failed target save. Keep the old identity and make retry explicit.
            workerSwitchPending = (try? vault.load("switch-target")) != nil ||
                ((try? SyncWriter.pendingReplacementBootstrap(vault: vault)) ?? nil) != nil
            workerSwitchCanContinue = (try? vault.load("switch-target")) != nil
            workerSwitchCanCancel = (try? SyncWriter.canCancelPendingReplacementBootstrap(vault: vault)) ?? false
            if !workerSwitchPending { await restoreOldServiceProjectionConsent() }
            syncMessage = LocalizedStatus(workerSwitchPending ? "mac.worker.switch.pending" : "mac.worker.switch.failed")
        }
    }
    private func restoreOldServiceProjectionConsent() async {
        await projectionClient?.setConsent(cfSyncEnabled && projectionEnabled && !rotationPending)
        if cfSyncEnabled && mcpEnabled && !mcpPending { await mcpClient?.resumeConsent() }
    }
    func cancelPendingWorkerSwitch() async {
        guard workerSwitchPending, workerSwitchCanCancel, !workerSwitchCanContinue, !cloudConnecting else { return }
        let alert = NSAlert()
        alert.messageText = L("mac.worker.switch.cancelTitle")
        alert.informativeText = L("mac.worker.switch.cancelInfo")
        alert.addButton(withTitle: L("settings.sync.cancelPendingSwitch"))
        alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SyncWriter.cancelPendingReplacementBootstrap(vault: vault)
            workerSwitchPending = false
            workerSwitchCanCancel = false
            await restoreOldServiceProjectionConsent()
            syncMessage = LocalizedStatus("mac.worker.switch.cancelled")
        } catch { syncMessage = LocalizedStatus("mac.worker.switch.pending") }
    }
    private func pendingSwitchTarget() throws -> WriterCredentials {
        try JSONDecoder().decode(WriterCredentials.self, from: vault.load("switch-target"))
    }
    func retryPendingWorkerSwitch() async {
        guard workerSwitchPending, !cloudConnecting, !mcpBusy, !shareBusy, !rotationPending, !rotationBusy else { return }
        cloudConnecting = true
        defer { cloudConnecting = false }
        do {
            try await resumePendingWorkerSwitch()
            syncMessage = LocalizedStatus("mac.worker.switch.done")
        } catch { syncMessage = LocalizedStatus("mac.worker.switch.pending") }
        workerSwitchCanContinue = (try? vault.contains("switch-target")) ?? false
        workerSwitchCanCancel = (try? SyncWriter.canCancelPendingReplacementBootstrap(vault: vault)) ?? false
    }
    private func resumePendingWorkerSwitch() async throws {
        let target: WriterCredentials
        do { target = try pendingSwitchTarget() }
        catch VaultError.unavailable {
            guard let pending = try SyncWriter.pendingReplacementBootstrap(vault: vault) else { throw SyncError.configuration }
            target = try await SyncWriter.bootstrap(endpoint: pending.endpoint, token: pending.token, vault: vault,
                supersedingStored: true, persist: false)
            try vault.save(JSONEncoder().encode(target), account: "switch-target")
            workerSwitchCanContinue = true
            workerSwitchCanCancel = false
        }
        let current = try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer"))
        if current.workspaceID == target.workspaceID && current.deviceID == target.deviceID && current.epoch == target.epoch && current.endpoint == target.endpoint {
            let next = try SyncWriter(credentials: target, directory: directory.appendingPathComponent("sync"))
            await stopPreviousMCPForSwitch()
            try SyncWriter.clearBootstrapRecovery(vault: vault)
            try vault.remove("switch-target")
            workerSwitchPending = false
            workerSwitchCanContinue = false
            workerSwitchCanCancel = false
            await teardownPreviousService()
            activate(next, credentials: target)
            return
        }
        let next = try SyncWriter(credentials: target, directory: directory.appendingPathComponent("sync"))
        if let retired = try RetiredServiceRevocation.pending(vault: vault) {
            guard retired.matches(current) else { throw SyncError.configuration }
            try await commitPendingWorkerSwitch(target: target, next: next)
            return
        }
        // Use an independent client so a failed DELETE does not turn off the
        // old in-memory uploader while its grant still exists remotely.
        try await RemoteMCPClient(credentials: current).disable()
        await mcpClient?.pause()
        mcpEnabled = false
        mcpPending = false
        UserDefaults.standard.set(false, forKey: "quota.mcp.consent")
        UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
        mcpMessage = LocalizedStatus("mac.mcp.revoked")
        let oldShares = try ShareWriter(credentials: current)
        for share in try await oldShares.list() where share.state != "revoked" {
            try await oldShares.revoke(shareId: share.shareId)
        }
        try await commitPendingWorkerSwitch(target: target, next: next)
    }
    private func commitPendingWorkerSwitch(target: WriterCredentials, next: SyncWriter) async throws {
        await stopPreviousMCPForSwitch()
        try SyncWriter.commitBootstrap(target, vault: vault)
        // A crash before marker removal is resolved by the identity check on restore.
        try vault.remove("switch-target")
        workerSwitchPending = false
        workerSwitchCanContinue = false
        workerSwitchCanCancel = false
        await teardownPreviousService()
        activate(next, credentials: target)
    }
    private func stopPreviousMCPForSwitch() async {
        await mcpClient?.pause()
        mcpEnabled = false
        mcpPending = false
        UserDefaults.standard.set(false, forKey: "quota.mcp.consent")
        UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
        mcpMessage = LocalizedStatus(retiredServicePending ? "mac.worker.retired.pending" : "mac.mcp.disabled")
    }
    func continuePendingWorkerSwitchKeepingOldAccess() async {
        guard workerSwitchPending, workerSwitchCanContinue, !cloudConnecting, !rotationPending,
              !rotationBusy, !shareBusy, !pairingBusy, !mcpBusy, !retiredCleanupBusy else { return }
        let alert = NSAlert()
        alert.messageText = L("mac.worker.retired.confirmTitle")
        alert.informativeText = L("mac.worker.retired.confirmInfo")
        alert.addButton(withTitle: L("settings.sync.continueSwitch"))
        alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cloudConnecting = true
        defer { cloudConnecting = false }
        do {
            let old = try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer"))
            let target = try pendingSwitchTarget()
            guard old.endpoint != target.endpoint || old.workspaceID != target.workspaceID else { throw SyncError.configuration }
            try RetiredServiceRevocation.retain(old, vault: vault)
            retiredServicePending = true
            retiredServiceMessage = LocalizedStatus("mac.worker.retired.pending")
            try await resumePendingWorkerSwitch()
            syncMessage = LocalizedStatus("mac.worker.retired.switched")
        } catch { syncMessage = LocalizedStatus("mac.worker.switch.pending") }
    }
    func retryRetiredServiceRevocation() async {
        guard retiredServicePending, !retiredCleanupBusy, !workerSwitchPending, !cloudConnecting else { return }
        retiredCleanupBusy = true
        defer { retiredCleanupBusy = false }
        do {
            guard let retired = try RetiredServiceRevocation.pending(vault: vault) else { throw SyncError.configuration }
            try await RemoteMCPClient(credentials: retired.credentials).disable()
            let oldShares = try ShareWriter(credentials: retired.credentials)
            for share in try await oldShares.list() where share.state != "revoked" {
                try await oldShares.revoke(shareId: share.shareId)
            }
            try RetiredServiceRevocation.clear(vault: vault)
            retiredServicePending = false
            retiredServiceMessage = LocalizedStatus("mac.worker.retired.revoked")
        } catch { retiredServiceMessage = LocalizedStatus("mac.worker.retired.pending") }
    }
    private func activate(_ next: SyncWriter, credentials: WriterCredentials) {
        writer = next
        cloudConnected = true
        syncEndpoint = credentials.endpoint
        shareWriter = try? ShareWriter(credentials: credentials)
        shareGeneration = UUID()
        shares = []
        clearShareInvitation()
        cfSyncEnabled = true
        UserDefaults.standard.set(true, forKey: SyncPreferenceKeys.cloudflare)
        projectionEnabled = false
        UserDefaults.standard.set(false, forKey: "quota.projectionConsent")
        Task {
            await configureProjection(credentials)
            await refreshShares()
            try? await configureMCP(credentials)
            if let snapshot { try? await next.upload(snapshot) }
        }
    }
    /// Drop local state bound to the service just replaced. Its workspace stays
    /// behind on the old Worker; the paired iPhone simply stops receiving
    /// updates until it pairs with the new service.
    private func teardownPreviousService() async {
        await projectionClient?.setConsent(false)
        await mcpClient?.pause()
        await writer?.setSyncEnabled(false)
        try? vault.remove("mcp-read-token")
        try? vault.remove("mcp-token-draft")
        mcpEnabled = false
        mcpPending = false
        UserDefaults.standard.set(false, forKey: "quota.mcp.consent")
        UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
        mcpEndpoint = ""
        mcpMessage = LocalizedStatus("mac.mcp.disabled")
        liveUpdateMessage = LocalizedStatus("mac.live.disabled")
        clearPairing()
    }
    func createPairing() {
        guard cfSyncEnabled, let writer, !workerSwitchPending, !cloudConnecting, !rotationPending, !rotationBusy, !pairingBusy else { return }
        pairingBusy = true
        Task { defer { pairingBusy = false }; do {
            let next = try await writer.createInvitation(); invitation = next; pairingLink = try next.encodedURL().absoluteString
            pairingOrigin = next.endpoint.absoluteString; pairingFingerprint = next.fingerprint
            message = LocalizedStatus("mac.pairing.openLink")
        } catch { message = LocalizedStatus("mac.pairing.createFailed") } }
    }
    func approvePairing() {
        guard cfSyncEnabled, let writer, let invitation, !workerSwitchPending, !cloudConnecting, !rotationPending, !rotationBusy, !pairingBusy else { return }
        pairingBusy = true
        Task { defer { pairingBusy = false }; do {
            let claim = try await writer.inspect(pairingID: invitation.pairingId)
            guard claim.state == "claimed" else { message = LocalizedStatus("mac.pairing.waitingRequest"); return }
            let alert = NSAlert(); alert.messageText = L("mac.pairing.approve.title")
            alert.informativeText = L("mac.pairing.approval.info", claim.deviceName ?? "iPhone", claim.recipientPublicKey ?? "")
            alert.addButton(withTitle: L("mac.pairing.approve.button")); alert.addButton(withTitle: L("mac.action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try await writer.approve(pairingID: invitation.pairingId, claim: claim); pairingLink = ""
            message = LocalizedStatus("mac.pairing.approved")
        } catch { message = LocalizedStatus("mac.pairing.approveFailed") } }
    }

    func manageDevices() {
        guard !workerSwitchPending, !cloudConnecting, !rotationPending, !rotationBusy, !pairingBusy, !mcpBusy else { return }
        rotationBusy = true
        Task { defer { rotationBusy = false }; do {
            let credentials = try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer"))
            let devices = try await SourceRotation.devices(credentials).filter { $0.role == "viewer" && !$0.revoked }
            guard !devices.isEmpty else { message = LocalizedStatus("mac.devices.empty"); return }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            picker.addItems(withTitles: devices.map { $0.name + " · " + String($0.deviceId.prefix(8)) })
            let alert = NSAlert(); alert.messageText = L("mac.devices.revoke.title")
            alert.informativeText = L("mac.devices.revoke.info")
            alert.accessoryView = picker; alert.addButton(withTitle: L("mac.devices.revoke.button")); alert.addButton(withTitle: L("mac.action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let selected = devices[picker.indexOfSelectedItem]
            let draft = try SourceRotation.prepare(credentials, devices: devices, revoking: [selected.deviceId])
            // One Keychain item owns the confirmed revocation intent, randomized keys,
            // and exact request bytes before either network mutation.
            try vault.save(JSONEncoder().encode(draft), account: "rotation-draft")
            try? vault.remove("pending-revoke")
            clearPairing()
            rotationPending = true
            await projectionClient?.setConsent(false)
            await writer?.pauseForRotation()
            await finishRotation()
        } catch { message = LocalizedStatus("mac.devices.rotationIncomplete") } }
    }
    func resumeRotation() async {
        guard rotationPending, !workerSwitchPending, !cloudConnecting, !rotationBusy, !pairingBusy, !mcpBusy else { return }
        rotationBusy = true
        defer { rotationBusy = false }
        clearPairing()
        await finishRotation()
    }
    private func finishRotation() async {
        do {
            let draft = try JSONDecoder().decode(RotationDraft.self, from: vault.load("rotation-draft"))
            // Construct all local post-commit state before mutating the server.
            let nextWriter = try SyncWriter(credentials: draft.next, directory: directory.appendingPathComponent("sync"))
            _ = try await SourceRotation.submit(draft, vault: vault)
            writer = nextWriter
            syncEndpoint = draft.next.endpoint
            shareWriter = try? ShareWriter(credentials: draft.next)
            shareGeneration = UUID()
            shares = []
            await nextWriter.setSyncEnabled(cfSyncEnabled)
            rotationPending = false; cloudConnected = true
            await refreshShares()
            await configureProjection(draft.next)
            await mcpClient?.pause()
            mcpEnabled = false
            mcpPending = false
            UserDefaults.standard.set(false, forKey: "quota.mcp.pending")
            UserDefaults.standard.set(false, forKey: "quota.mcp.consent")
            try await configureMCP(draft.next)
            mcpMessage = LocalizedStatus("mac.rotation.mcpTokenInvalidated")
            message = LocalizedStatus("mac.rotation.done")
            if cfSyncEnabled, let snapshot {
                do { try await nextWriter.upload(snapshot) }
                catch { message = LocalizedStatus("mac.rotation.uploadPending") }
            }
        } catch { rotationPending = true; message = LocalizedStatus("mac.rotation.pending") }
    }
    var canShare: Bool { cfSyncEnabled && shareWriter != nil && !connecting && !rotationPending && !rotationBusy && !cloudConnecting && !workerSwitchPending }

    func clearShareInvitation() {
        shareInviteLink = ""
        shareInvitationID = nil
    }

    func refreshShares() async {
        guard !shareBusy, let shareWriter, !rotationPending else { return }
        shareBusy = true
        defer { shareBusy = false }
        do {
            var records = try await shareWriter.list()
            // A previous crash may have left a grant for an inactive account.
            let active = connectionConfiguration?.connections.filter(\.isEnabled) ?? []
            let orphaned = records.filter { share in
                share.state != "revoked" && !active.contains {
                    $0.id == share.connectionId && $0.providerID == share.providerId && $0.accountID == share.accountId
                }
            }
            for share in orphaned { try await shareWriter.revoke(shareId: share.shareId) }
            if !orphaned.isEmpty { records = try await shareWriter.list() }
            shares = records
            shareMessage = LocalizedStatus(orphaned.isEmpty ? "mac.share.loaded" : "mac.share.orphansRevoked")
            if let snapshot { await publishShares(snapshot) }
        } catch {
            shares = []
            shareMessage = LocalizedStatus("mac.share.loadFailed")
        }
    }

    func createShare(connectionID: String) async {
        guard !shareBusy, canShare, let shareWriter,
              let connection = connectionConfiguration?.connections.first(where: { $0.id == connectionID && $0.isEnabled })
        else { shareMessage = LocalizedStatus("mac.share.needsWriter"); return }
        shareBusy = true
        defer { shareBusy = false }
        clearShareInvitation()
        do {
            let invitation = try await shareWriter.create(
                connectionId: connection.id, providerId: connection.providerID,
                accountId: connection.accountID, label: connection.accountAlias)
            // Only the QR/link contains the one-time secret, never the projection.
            shareInviteLink = try invitation.encodedURL().absoluteString
            shareInvitationID = invitation.shareId
            shareMessage = LocalizedStatus("mac.share.inviteReady")
            do { shares = try await shareWriter.list() }
            catch { shareMessage = LocalizedStatus("mac.share.loadFailed") }
            if let snapshot { await publishShares(snapshot) }
        } catch { shareMessage = LocalizedStatus("mac.share.createFailed") }
    }

    func approveShare(_ share: ShareRecord) async {
        guard !shareBusy, canShare, let shareWriter, share.state == "claimed",
              let claimID = share.claimId, let code = share.verificationCode else { return }
        let alert = NSAlert()
        alert.messageText = L("mac.share.approveTitle")
        alert.informativeText = L("mac.share.approveInfo", share.recipientName ?? "", code)
        alert.addButton(withTitle: L("mac.share.approveButton"))
        alert.addButton(withTitle: L("mac.action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shareBusy = true
        defer { shareBusy = false }
        do {
            try await shareWriter.approve(shareId: share.shareId, claimId: claimID)
            shares = try await shareWriter.list()
            shareMessage = LocalizedStatus("mac.share.approved")
            if let snapshot { await publishShares(snapshot) }
        } catch { shareMessage = LocalizedStatus("mac.share.approveFailed") }
    }

    func revokeShare(_ share: ShareRecord) async {
        guard !shareBusy, let shareWriter else { return }
        shareBusy = true
        defer { shareBusy = false }
        do {
            try await shareWriter.revoke(shareId: share.shareId)
            if shareInvitationID == share.shareId { clearShareInvitation() }
            shares = try await shareWriter.list()
            shareMessage = LocalizedStatus("mac.share.revoked")
        } catch { shareMessage = LocalizedStatus("mac.share.revokeFailed") }
    }

    private func revokeShares(for connections: [ProviderConnectionRecord]) async throws {
        guard !connections.isEmpty else { return }
        guard !rotationPending, let shareWriter else {
            if syncEndpoint != nil { throw ShareRevocationFailure() }
            return
        }
        // Reconcile with the service before changing local state. Offline or
        // unconfirmed revocation blocks the pause/delete; retry the action.
        let records = try await shareWriter.list()
        for share in records where share.state != "revoked" && connections.contains(where: {
            $0.id == share.connectionId && $0.providerID == share.providerId && $0.accountID == share.accountId
        }) {
            try await shareWriter.revoke(shareId: share.shareId)
            if shareInvitationID == share.shareId { clearShareInvitation() }
        }
        shares = try await shareWriter.list()
    }

    private func revokeAllShares() async throws {
        guard let shareWriter else { throw ShareRevocationFailure() }
        let records = try await shareWriter.list()
        for share in records where share.state != "revoked" {
            try await shareWriter.revoke(shareId: share.shareId)
        }
        shares = try await shareWriter.list()
        clearShareInvitation()
    }

    private func publishShares(_ snapshot: Snapshot) async {
        guard cfSyncEnabled, let shareWriter, !rotationPending, !workerSwitchPending else { return }
        let generation = shareGeneration
        for share in shares where share.state == "approved" {
            guard generation == shareGeneration, !rotationPending, !workerSwitchPending,
                  connectionConfiguration?.connections.contains(where: {
                      $0.id == share.connectionId && $0.providerID == share.providerId &&
                      $0.accountID == share.accountId && $0.isEnabled
                  }) == true else { continue }
            guard let projection = ShareProjection.selected(snapshot, for: share) else {
                shareMessage = LocalizedStatus("mac.share.tooManyWindows")
                continue
            }
            do { try await shareWriter.publish(shareId: share.shareId, projection: projection) }
            catch { shareMessage = LocalizedStatus("mac.share.publishFailed") }
        }
    }
    private func receivedKey(endpoint: URL, shareID: String) -> String {
        endpoint.absoluteString + "/" + shareID
    }

    func claimSharedLink(_ link: String, recipientName: String) async {
        guard !receivingBusy else { return }
        receivingBusy = true
        defer { receivingBusy = false }
        do {
            let name = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 48,
                  let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw SyncError.configuration }
            let invitation = try ShareInvitation.parse(url)
            let key = receivedKey(endpoint: invitation.endpoint, shareID: invitation.shareId)
            guard !receivedClaims.contains(where: { receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) == key }),
                  !receivedGrants.contains(where: { receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) == key })
            else { throw SyncError.configuration }
            let claim = try await ShareRecipient.claim(invitation: invitation, recipientName: name)
            let next = receivedClaims + [claim]
            try vault.save(JSONEncoder().encode(StoredReceivedShares(claims: next, grants: receivedGrants)),
                           account: "received-shares")
            receivedClaims = next
            receivingMessage = LocalizedStatus("mac.share.claimPending")
        } catch { receivingMessage = LocalizedStatus("mac.share.claimFailed") }
    }

    func refreshReceivedShares() async {
        guard !receivingBusy else { return }
        receivingBusy = true
        defer { receivingBusy = false }
        var failures = false
        for claim in receivedClaims {
            do {
                guard let grant = try await ShareRecipient.result(claim: claim) else { continue }
                let nextGrants = receivedGrants.contains(where: {
                    receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) ==
                        receivedKey(endpoint: grant.endpoint, shareID: grant.shareId)
                }) ? receivedGrants : receivedGrants + [grant]
                let nextClaims = receivedClaims.filter {
                    receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) !=
                        receivedKey(endpoint: claim.endpoint, shareID: claim.shareId)
                }
                try vault.save(JSONEncoder().encode(StoredReceivedShares(claims: nextClaims, grants: nextGrants)),
                               account: "received-shares")
                receivedGrants = nextGrants
                receivedClaims = nextClaims
                receivingMessage = LocalizedStatus("mac.share.grantReady")
            } catch { failures = true }
        }
        for grant in receivedGrants {
            let key = receivedKey(endpoint: grant.endpoint, shareID: grant.shareId)
            do { receivedProjections[key] = try await ShareRecipient.projection(grant: grant) }
            catch {
                receivedProjections.removeValue(forKey: key)
                failures = true
            }
        }
        if failures { receivingMessage = LocalizedStatus("mac.share.receiveFailed") }
    }

    func receivedProjection(for grant: ShareGrant) -> ShareProjection? {
        receivedProjections[receivedKey(endpoint: grant.endpoint, shareID: grant.shareId)]
    }

    func removeReceivedShare(endpoint: URL, shareID: String) {
        let key = receivedKey(endpoint: endpoint, shareID: shareID)
        do {
            let claims = receivedClaims.filter { receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) != key }
            let grants = receivedGrants.filter { receivedKey(endpoint: $0.endpoint, shareID: $0.shareId) != key }
            try vault.save(JSONEncoder().encode(StoredReceivedShares(claims: claims, grants: grants)),
                           account: "received-shares")
            receivedClaims = claims
            receivedGrants = grants
            receivedProjections.removeValue(forKey: key)
            receivingMessage = LocalizedStatus("mac.share.removedLocal")
        } catch { receivingMessage = LocalizedStatus("mac.share.receiveFailed") }
    }
    private func clearPairing() {
        invitation = nil
        pairingLink = ""; pairingOrigin = ""; pairingFingerprint = ""
    }
    func showDiagnostics() {
        Task {
            let health = await collector?.diagnostics() ?? []
            let rows = health.map { value in
                let duration = value.lastDuration.map { L("mac.diagnostics.duration", $0) } ?? L("mac.diagnostics.notMeasured")
                let due = value.nextDue.map { $0.formatted(date: .omitted, time: .standard) } ?? L("mac.diagnostics.waitingDue")
                return L("mac.diagnostics.row", value.providerID, value.outcome.rawValue, duration, value.failures, due)
            }
            let alert = NSAlert(); alert.messageText = L("mac.diagnostics.title")
            alert.informativeText = (rows.isEmpty ? L("mac.diagnostics.noSources") : rows.joined(separator: "\n\n")) + L("mac.diagnostics.privacyNote")
            alert.runModal()
        }
    }
    func stop() async {
        collectionProgress = nil
        await collector?.stop(); await ipc.stop(); collector = nil; connected = false
    }
}
