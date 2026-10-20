import SwiftUI
import Combine
import QuotaPhone
import QuotaCore
import QuotaDesign
import QuotaSync
import QuotaStore
import QuotaWidgets
import WidgetKit
import ActivityKit
import CryptoKit
import CloudKit
import UserNotifications

@main
struct AmmoPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let fixtureRequested: Bool
    private let fixture: Snapshot?

    init() {
        PhoneFileTransactionExecution.install()
#if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--fixture"), arguments.indices.contains(index + 1) {
            fixtureRequested = true
            fixture = try? SnapshotCodec.decode(Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
        } else {
            fixtureRequested = false
            fixture = nil
        }
#else
        fixtureRequested = false
        fixture = nil
#endif
        if PairedEnvironment.group.hasPrefix("group."), let defaults = UserDefaults(suiteName: PairedEnvironment.group) {
            L10n.install(additionalDefaults: defaults)
        }
        // Task handlers must exist before the app finishes launching; the host
        // installs the refresh closure once its sync state is ready.
        PhoneBackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            PhoneHost(fixtureRequested: fixtureRequested, fixture: fixture)
                .task {
                    #if DEBUG
                    if fixtureRequested && CommandLine.arguments.contains("--fixture-file-transaction-check") {
                        await PhoneFileTransactionExecution.runFixtureCheck()
                    }
                    #endif
                }
        }
    }
}

/// Only the application host may request UIApplication execution time. Widget
/// extensions retain their system-managed execution lifetime and never call it.
@MainActor
private final class PhoneFileTransactionExecution {
    static func install() {
        FileTransaction.installProtectionProvider {
            if Thread.isMainThread {
                return try MainActor.assumeIsolated { try begin() }
            }
            return try DispatchQueue.main.sync {
                try MainActor.assumeIsolated { try begin() }
            }
        }
    }

    private static func begin() throws -> FileTransactionProtection {
        try PhoneFileTransactionBackgroundAssertion.begin(start: { expired in
            let identifier = UIApplication.shared.beginBackgroundTask(withName: "Ammo file transaction") { @Sendable in
                MainActor.assumeIsolated { expired() }
            }
            return identifier == .invalid ? nil : identifier.rawValue
        }, end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) })
    }

    #if DEBUG
    /// Synthetic simulator probe for the real UIKit adapter. Never uses pairing,
    /// shared containers, provider data, or the release application's cache.
    static func runFixtureCheck() async {
        struct Receipt: Codable { var cacheAdmission: Bool; var cancellationPreservedCache: Bool }
        let receipt: Receipt
        do {
            receipt = try await Task.detached {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-transaction-fixture-" + UUID().uuidString)
                let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
                let snapshot = try Snapshot.make(windows: [], deviceID: "fixture", epoch: "fixture", sequence: 1, capturedAt: Date())
                let trust = SourceTrust(workspaceID: "fixture", deviceID: "fixture", epoch: "fixture", keyID: "fixture", publicKey: signer.publicKey.rawRepresentation)
                let cache = try VerifiedCache(directory: directory, trust: trust)
                let bytes = try EnvelopeCodec.seal(snapshot, workspaceID: "fixture", keyID: "fixture", key: key, signingKey: signer)
                let accepted = try await cache.accept(bytes, key: key)
                let cancellationRejected = await Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do { _ = try await cache.accept(bytes, key: key); return false }
                    catch is CancellationError { return true }
                    catch { return false }
                }.value
                let restored = try await cache.latest(key: key)
                return Receipt(cacheAdmission: accepted.sourceSequence == 1,
                               cancellationPreservedCache: cancellationRejected && restored?.sourceSequence == 1)
            }.value
        } catch { receipt = Receipt(cacheAdmission: false, cancellationPreservedCache: false) }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONEncoder().encode(receipt) {
            try? data.write(to: directory.appendingPathComponent("file-transaction-fixture.json"), options: .atomic)
        }
    }
    #endif
}

/// Forwards the system APNs registration outcome to the alert registrar.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !CommandLine.arguments.contains("--fixture") { UNUserNotificationCenter.current().delegate = self }
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(ResetReminderPolicy.prefix) ? [.banner, .list, .sound] : []
    }
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: AlertPushRegistrar.deviceTokenNotification, object: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: AlertPushRegistrar.deviceTokenNotification, object: nil)
    }
}

/// Secondary pages pushed on top of a section; the tab bar hides while one is open.
private enum PhoneRoute: Hashable {
    case shares
    case widgets
    case monitor
}

@MainActor
private struct PhoneHost: View {
    let fixtureRequested: Bool
    @State private var snapshot: Snapshot?
    @State private var refreshFreshness = PhoneRefreshFreshness.verified
    @State private var cfEnabled = false
    @State private var iCloudEnabled = false
    @State private var iCloudClient: ICloudSnapshotSync?
    @State private var syncGeneration = UUID()
    @State private var credentialTransition = PhoneCredentialTransition()
    @State private var syncReady = false
    @State private var refreshAgain = false
    @State private var displayingCF = false
    @State private var iCloudMessage = L("phone.icloud.message.off")
    @State private var client: SnapshotClient?
    @State private var usageClient: UsageSnapshotClient?
    @State private var tokenUsage: TokenUsageSnapshot?
    @State private var usageStale = true
    @State private var usageMessage: String?
    @State private var invitation: PairingInvitation?
    @State private var claim: PairingClaim?
    @State private var link = ""
    @State private var message: String
    @State private var busy = false
    @State private var confirm = false
    @State private var proposedCredentials: ViewerCredentials?
    @State private var rotationConfirmation: RotationConfirmation?
    @State private var confirmRotation = false
    @StateObject private var registrar: RemoteActivityRegistrar
    @StateObject private var groupRegistrar: RemoteGroupRegistrar
    @StateObject private var alertRegistrar = AlertPushRegistrar()
    @StateObject private var resetReminders = ResetReminderCoordinator.local()
    @State private var coordinator: QuotaActivityCoordinator
    @State private var groupCoordinator: QuotaGroupActivityCoordinator
    @State private var displayIntent = SingleActivityDisplayIntent()
    @State private var displayQueue: Task<Void, Never>?
    @State private var fixtureCheckRan = false
    @State private var activeSessions: [String: String] = [:]
    @State private var monitoringSelection = MonitoringSelection()
    @State private var monitoringSelectionLoaded = false
    @State private var widgetSelection: [String] = []
    @AppStorage("quota.activity.compactStyle") private var compactStyle = ActivityCompactStyle.ring.rawValue
    @AppStorage("quota.activity.showWindowName") private var showWindowName = true
    @AppStorage("quota.activity.showProgress") private var showProgress = true
    @AppStorage(QuotaAppearanceKeys.displayStyle) private var storedDisplayStyle = QuotaDisplayStyle.calibrated.rawValue
    @State private var currentCredentialScope = ""
    @State private var connectedMode: SyncServiceMode?
    @State private var section = PhoneSection.overview
    @State private var path: [PhoneRoute] = []
    @State private var widgetFeedback: String?
    @State private var sharedInviteURL: URL?
    @State private var shareRefreshGeneration = UUID()
    @State private var languageRevision = L10n.revision
    private var refreshIdentity: PhoneRefreshIdentity {
        PhoneRefreshIdentity(generation: syncGeneration, credentialScope: currentCredentialScope, clientIdentifier: client.map(ObjectIdentifier.init))
    }
    private var remoteUpdatesAvailable: Bool { !fixtureRequested && cfEnabled && displayingCF && groupRegistrar.available }
    private var fixtureActivityCheck: Bool {
        #if DEBUG
        fixtureRequested && CommandLine.arguments.contains("--fixture-activity-check")
        #else
        false
        #endif
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    init(fixtureRequested: Bool, fixture: Snapshot?) {
        self.fixtureRequested = fixtureRequested
        let registrar = RemoteActivityRegistrar()
        _registrar = StateObject(wrappedValue: registrar)
        _coordinator = State(initialValue: QuotaActivityCoordinator(tokenRegistrar: registrar))
        let groupRegistrar = RemoteGroupRegistrar()
        _groupRegistrar = StateObject(wrappedValue: groupRegistrar)
        _groupCoordinator = State(initialValue: QuotaGroupActivityCoordinator(tokenRegistrar: groupRegistrar))
        _snapshot = State(initialValue: fixture)
        _message = State(initialValue: fixtureRequested
            ? (fixture == nil ? L("phone.init.fixtureUnreadable") : L("phone.init.fixtureNote"))
            : L("phone.init.getStarted"))
        #if DEBUG
        if fixtureRequested {
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--fixture-section"), arguments.indices.contains(index + 1) {
                switch arguments[index + 1] {
                case "usage": _section = State(initialValue: .usage)
                case "settings": _section = State(initialValue: .settings)
                default: break
                }
            }
            if let index = arguments.firstIndex(of: "--fixture-usage"), arguments.indices.contains(index + 1),
               let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])),
               let usage = try? TokenUsageSnapshotCodec.decode(data) {
                _tokenUsage = State(initialValue: usage)
            }
        }
        if fixtureRequested && CommandLine.arguments.contains("--fixture-monitor") {
            _section = State(initialValue: .settings)
            _path = State(initialValue: [.monitor])
            if CommandLine.arguments.contains("--fixture-selected"), let fixture {
                _monitoringSelection = State(initialValue: MonitoringSelection(windowIDs: Array(fixture.windows.prefix(2).map(\.id))))
            }
        }
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    if section == .overview {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            QuotaPhoneView(
                                values: snapshot?.windows.map { QuotaPresentation(window: $0, now: context.date, offline: refreshFreshness.isOffline) } ?? [],
                                now: context.date,
                                remoteUpdatesConfigured: remoteUpdatesAvailable
                            )
                        }
                        // Sync status stays readable but quiet under the orbits,
                        // so the featured reading owns the top of the screen.
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                if busy { ProgressView().controlSize(.mini) }
                                Text(message)
                            }
                            if fixtureRequested {
                                Label(L("phone.overview.fixtureBadge"), systemImage: "testtube.2").fontWeight(.semibold)
                            } else {
                                Text(L("phone.overview.foregroundHint"))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32).padding(.top, 8)
                    } else if section == .usage {
                        TokenUsagePhoneView(snapshot: tokenUsage, stale: usageStale,
                                            message: fixtureRequested ? (tokenUsage == nil ? L("tokenUsage.fixtureUnavailable") : L("phone.init.fixtureNote")) : usageMessage)
                    } else if section == .settings {
                    StatusCard(message: message, busy: busy)
                    if !fixtureRequested {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("phone.settings.sync.title")).font(.title2.bold())
                            Toggle(L("phone.settings.sync.icloud"), isOn: $iCloudEnabled).disabled(busy)
                            Text(L("phone.settings.sync.icloud.footer"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(iCloudMessage).font(.caption)
                            Toggle(L("phone.settings.sync.cloudflare"), isOn: $cfEnabled).disabled(busy)
                            Text(L("phone.settings.sync.cloudflare.footer"))
                                .font(.caption).foregroundStyle(.secondary)
                            if client != nil, let connectedMode {
                                HStack(spacing: 6) {
                                    Image(systemName: connectedMode == .official ? "checkmark.seal.fill" : "server.rack")
                                    Text(L("phone.settings.sync.connected",
                                           connectedMode == .official ? L("phone.sync.mode.official") : L("phone.sync.mode.selfHosted")))
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Button(L("phone.action.refreshQuotas")) { Task { await refresh() } }.disabled(busy || (!cfEnabled && !iCloudEnabled))
                        }.padding(16).background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 16)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("phone.settings.reminders.title")).font(.title2.bold())
                            Toggle(L("phone.alerts.toggle"), isOn: Binding(
                                get: { alertRegistrar.enabled },
                                set: { on in Task { await alertRegistrar.setEnabled(on) } }
                            )).disabled(busy || !cfEnabled)
                            Text(L("phone.alerts.footer"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(alertRegistrar.status.text).font(.caption)
                            Divider()
                            ResetReminderSettingsView(coordinator: resetReminders).disabled(fixtureRequested)
                        }.padding(16).background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 16)
                    }
                    if !fixtureRequested && cfEnabled && client == nil {
                        PhonePairingSetup(
                            link: $link,
                            invitation: invitation,
                            claim: claim,
                            busy: busy,
                            inspect: { inspect(link) },
                            onScan: { inspect($0) },
                            onScanUnavailable: { message = $0 },
                            requestPairing: { Task { await beginPairing() } },
                            complete: { Task { await completePairing() } }
                        )
                    }
                    if !fixtureRequested {
                        NavigationLink(value: PhoneRoute.shares) {
                            PhoneLinkRow(symbol: "person.2", title: L("phone.shares.title"), detail: L("phone.shares.summary"))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                    NavigationLink(value: PhoneRoute.monitor) {
                        PhoneLinkRow(symbol: "waveform.path", title: L("phone.section.monitor"), detail: L("phone.monitor.summary"))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    PhoneAppearanceSettings().padding(.horizontal, 20)
                    PhoneLanguageSettings().padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }
            .id(section)
            .id(languageRevision)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChange)) { _ in
                languageRevision = L10n.revision
            }
            .background(PaperInk(scheme).canvas)
            .tint(PaperInk(scheme).accent)
            .navigationTitle(section == .overview ? L("phone.section.overview") : section == .usage ? L("tokenUsage.title") : L("phone.section.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .shares: sharesPage
                case .widgets: widgetsPage
                case .monitor: monitorPage
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PhoneSectionBar(selected: section) { section = $0; path = [] }
            }
            .refreshable { await refresh() }
            .toolbar {
                if !fixtureRequested {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await refresh() } } label: {
                            if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .accessibilityLabel(L("phone.action.refreshQuotas"))
                        .disabled(busy || (!cfEnabled && !iCloudEnabled))
                    }
                }
            }
            .task {
                groupCoordinator.onActivityStateChanged = { syncActiveActivities() }
                #if DEBUG
                if fixtureActivityCheck && scenePhase == .active { await runFixtureActivityCheck() }
                #endif
                if !fixtureRequested {
                    restoreTransportPreferences()
                    // Background wakes reuse the exact foreground refresh path.
                    PhoneBackgroundRefresh.performRefresh = { await refresh() }
                    coordinator.onActivityStateChanged = { _ in syncActiveActivities() }
                    persistWidgetDisplayStyle(storedDisplayStyle)
                    await reconcileActivitySelection()
                    coordinator.recoverExistingActivities()
                    groupCoordinator.recoverExistingActivities()
                    syncActiveActivities()
                    await restore()
                    if !path.contains(.shares) { await ReceivedSharesForeground.refresh() }
                }
            }
            .onChange(of: cfEnabled) { _, enabled in
                guard !fixtureRequested else { return }
                PhoneActivityTransportPolicy.preferenceChanged(enabled: enabled,
                    invalidateGroup: { groupRegistrar.markDisabled() }, invalidateLegacy: { registrar.markDisabled() })
                guard syncReady else { return }
                syncGeneration = UUID()
                PairedEnvironment.setSyncEnabled(enabled, key: SyncPreferenceKeys.cloudflare)
                if PhoneResetReminderSourcePolicy.shouldCancel(source: resetReminders.source, eligibilitySource: resetReminders.eligibilitySource, cfRevoked: false, iCloudRevoked: false,
                        cfEnabled: enabled, iCloudEnabled: iCloudEnabled) || (!enabled && !iCloudEnabled) { resetReminders.invalidateSource() }
                if !enabled && !iCloudEnabled { try? PairedEnvironment.clearWidgetWindowChoices() }
                let transportGeneration = syncGeneration
                if !enabled {
                    Task {
                        await PhoneActivityTransportPolicy.disable(
                            isCurrent: { transportGeneration == syncGeneration && !cfEnabled },
                            group: { await groupRegistrar.disable() }, legacy: { await registrar.disable() })
                    }
                }
                if !enabled {
                    alertRegistrar.deconfigure()
                    usageClient = nil; tokenUsage = nil; usageStale = true
                    usageMessage = L("tokenUsage.sync.requiresWorker")
                }
                Task {
                    guard transportGeneration == syncGeneration, enabled == cfEnabled else { return }
                    if enabled, let credentials = try? PairedEnvironment.credentials() {
                        client = try? PairedEnvironment.client(credentials)
                        usageClient = try? PairedEnvironment.usageClient(credentials)
                        currentCredentialScope = RemoteActivityRegistrar.scope(credentials)
                        let identity = refreshIdentity
                        guard await configureActivityRegistrars(credentials, identity: identity) else { return }
                        await alertRegistrar.configure(credentials)
                        guard identity == refreshIdentity, cfEnabled else { return }
                    }
                    await refresh()
                }
            }
            .onChange(of: iCloudEnabled) { _, enabled in
                guard !fixtureRequested, syncReady else { return }
                syncGeneration = UUID()
                PairedEnvironment.setSyncEnabled(enabled, key: SyncPreferenceKeys.iCloud)
                if PhoneResetReminderSourcePolicy.shouldCancel(source: resetReminders.source, eligibilitySource: resetReminders.eligibilitySource, cfRevoked: false, iCloudRevoked: false,
                        cfEnabled: cfEnabled, iCloudEnabled: enabled) || (!enabled && !cfEnabled) { resetReminders.invalidateSource() }
                if !enabled && !cfEnabled { try? PairedEnvironment.clearWidgetWindowChoices() }
                if !enabled { iCloudMessage = L("phone.icloud.message.disabled") }
                Task { await refresh() }
            }
            // CloudKit delivers this notification on a background queue; the
            // closure mutates @State, so it must hop to the main thread first.
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)) { _ in
                guard !fixtureRequested, syncReady, iCloudEnabled else { return }
                syncGeneration = UUID()
                try? PairedEnvironment.iCloudCache().clear()
                if !displayingCF { snapshot = nil }
                if PhoneResetReminderSourcePolicy.shouldCancel(source: resetReminders.source, eligibilitySource: resetReminders.eligibilitySource, cfRevoked: false, iCloudRevoked: true,
                        cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled) { resetReminders.invalidateSource() }
                WidgetCenter.shared.reloadAllTimelines()
                Task { await refresh() }
            }
            .onOpenURL { if !fixtureRequested { handleDeepLink($0) } }
            .onChange(of: storedDisplayStyle) { _, value in
                persistWidgetDisplayStyle(value)
                if !fixtureRequested { WidgetCenter.shared.reloadAllTimelines() }
            }
            .onChange(of: scenePhase) { _, value in
                if value != .active && displayIntent.phase == .creating {
                    displayIntent.needsRestart(); persistDisplayIntent()
                }
                #if DEBUG
                if value == .active && fixtureActivityCheck { Task { await runFixtureActivityCheck() } }
                #endif
                if value == .active {
                    if !fixtureRequested {
                        Task {
                            await reconcileActivitySelection()
                            coordinator.recoverExistingActivities()
                            groupCoordinator.recoverExistingActivities()
                            syncActiveActivities()
                            await refresh()
                        }
                        shareRefreshGeneration = UUID()
                        if !path.contains(.shares) {
                            Task { await ReceivedSharesForeground.refresh() }
                        }
                    }
                }
                if value == .background, !fixtureRequested {
                    // Leaving the screen arms the system app-refresh request so the
                    // snapshot and running island sessions stay as fresh as iOS allows.
                    PhoneBackgroundRefresh.schedule()
                }
            }
            .alert(L("phone.alert.rotation.title"), isPresented: $confirmRotation) {
                Button(L("phone.alert.rotation.confirm")) { Task { await acceptRotation() } }
                Button(L("phone.alert.rotation.later"), role: .cancel) { proposedCredentials = nil }
            } message: {
                Text(rotationConfirmation.map {
                    L("phone.alert.rotation.message", $0.origin, $0.oldFingerprint, $0.newFingerprint)
                } ?? L("phone.alert.rotation.unavailable"))
            }
            .alert(L("phone.alert.pairing.title"), isPresented: $confirm) {
                Button(L("phone.alert.pairing.confirm")) { Task { await beginPairing() } }
                Button(L("phone.action.cancel"), role: .cancel) { invitation = nil }
            } message: {
                Text(L("phone.alert.pairing.message", invitation?.endpoint.absoluteString ?? "", invitation?.fingerprint ?? ""))
            }
        }
        // The 60s loop is foreground-only: SwiftUI cancels the sleep when the
        // scene leaves active. Background wakeups go through the scheduled
        // BGAppRefreshTask instead — never a polling loop of our own.
        .task(id: scenePhase) {
            guard scenePhase == .active, !fixtureRequested else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                if syncReady && !busy && !confirm && !confirmRotation && (cfEnabled || iCloudEnabled) {
                await refresh()
                }
            }
        }
    }

    /// Each quota has a Lock Screen display action and its latest display status.
    /// The selection survives system expiry until the user stops it. A selected
    /// window that left the snapshot still gets a row so it stays endable. Style and
    /// content choices only affect new sessions, so they stay folded away.
    private func islandCard(_ windows: [QuotaWindow]) -> some View {
        let options = windows.filter { $0.remainingBps != nil }
        let optionIDs = Set(options.map(\.id))
        let orphanWindowIDs = monitoringSelection.windowIDs.filter { !optionIDs.contains($0) }
        let activeWindows = options.filter { activeSessions.values.contains($0.id) }
        let stylePreview = (activeWindows.isEmpty ? options : activeWindows).prefix(2)
            .map { QuotaPresentation(window: $0, now: .now, offline: refreshFreshness.isOffline) }
        let optionGroups = QuotaProviderGroup.groups(
            options.map { QuotaPresentation(window: $0, now: .now, offline: refreshFreshness.isOffline) }
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(L("phone.island.title"), systemImage: "capsule.fill").font(.headline)
                Spacer()
                Text(L("phone.monitor.slotCount", monitoringSelection.windowIDs.count, MonitoringSessionPolicy.maximumConcurrentSessions))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(activeSessions.isEmpty ? PaperInk(scheme).muted : PaperInk(scheme).accent)
            }
            if options.isEmpty && orphanWindowIDs.isEmpty {
                Text(L("phone.monitor.noneAvailable"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(optionGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    PhoneProviderGroupHeader(providerID: group.providerID)
                    ForEach(group.values, id: \.window.id) { value in
                        PhoneLockScreenSelectionRow(
                            value: value,
                            isOn: Binding(
                                get: { monitoringSelection.windowIDs.contains(value.window.id) },
                                set: { on in
                                    guard !busy else { return }
                                    selectMonitoring(windowID: value.window.id, selected: on)
                                }
                            ),
                            statusText: monitoringRowStatus(windowID: value.window.id)
                        )
                        .disabled(busy)
                    }
                }
            }
            ForEach(orphanWindowIDs, id: \.self) { orphanSelectionRow(windowID: $0) }
            HStack(spacing: 12) {
                Button(L(displayIntent.phase == .stopped ? "phone.monitor.start" : "phone.monitor.restart")) { requestGroupDisplay() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !monitoringSelection.windowIDs.contains(where: { optionIDs.contains($0) }))
                    .accessibilityIdentifier("singleActivity.show")
                if displayIntent.wantsDisplay || !activeSessions.isEmpty {
                    Button(L("phone.monitor.end")) { stopGroupDisplay() }
                        .buttonStyle(.bordered).accessibilityIdentifier("singleActivity.stop")
                }
            }
            if !remoteUpdatesAvailable {
                Text(L("phone.remote.group.localFallback")).font(.caption).foregroundStyle(.secondary)
            }
            if groupRegistrar.cleanupPending {
                Text(L("phone.remote.group.cleanupPending")).font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot, !monitoringSelection.windowIDs.isEmpty,
               let preview = try? ActivityGroupProjection(snapshot: snapshot, windowIDs: monitoringSelection.windowIDs, offline: refreshFreshness.isOffline) {
                ActivityGroupCardView(descriptors: preview.descriptors, content: preview.content,
                    endsAt: Int64(Date.now.addingTimeInterval(8 * 60 * 60).timeIntervalSince1970))
                    .padding(12).background(PaperInk(scheme).elevated, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("phone.monitor.selection.footer"))
                Text(L("phone.monitor.collection.footer"))
                Text(L("phone.monitor.footer"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    PhoneIslandStylePicker(style: $compactStyle, values: Array(stylePreview.prefix(1)))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("phone.monitor.content.title")).font(.subheadline.weight(.semibold))
                        Toggle(L("phone.monitor.showWindowName"), isOn: $showWindowName)
                        Toggle(L("phone.monitor.showProgress"), isOn: $showProgress)
                        Text(L("phone.monitor.content.footer"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)
            } label: {
                Text(L("phone.monitor.appearance")).font(.subheadline.weight(.semibold))
            }
        }
    }

    private func monitoringRowStatus(windowID: String) -> String? {
        let window = snapshot?.windows.first { $0.id == windowID }
        let sourceState = window.map { QuotaRules.state($0, now: .now) }
        if !displayIntent.wantsDisplay { return monitoringSelection.windowIDs.contains(windowID) ? L("phone.monitor.group.selected") : nil }
        let systemStale = Activity<QuotaGroupActivityAttributes>.activities.contains {
            $0.attributes.descriptors.contains { $0.windowID == windowID } && $0.activityState == .stale &&
                ($0.content.state.rows.first { $0.windowID == windowID }?.staleAt.map { $0 <= Int64(Date.now.timeIntervalSince1970) } ?? true)
        }
        let stale = systemStale || (sourceState.map { [.stale, .resetPending, .authRequired, .unavailable, .locked, .clockSkew].contains($0) } ?? true)
        switch monitoringSelection.rowState(windowID: windowID, runningWindowIDs: activeSessions.values, offline: refreshFreshness.isOffline, stale: stale) {
        case .off: return nil
        case .systemEnded: return L("phone.monitor.systemEnded")
        case .offline: return L("widget.activity.offline")
        case .stale:
            switch sourceState {
            case .authRequired: return L("widget.activity.auth.required")
            case .resetPending: return L("widget.activity.reset.pending")
            case .locked: return L("widget.locked")
            case .unavailable: return L("widget.activity.quota.unknown")
            case .clockSkew: return L("widget.activity.clock.skew")
            default: return L("widget.activity.stale")
            }
        case .live:
            guard let sessionID = displayIntent.sessionID else { return nil }
            let remote = Activity<QuotaGroupActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }?.attributes.remoteUpdates == true
            return remote ? (groupRegistrar.sessionStatus[sessionID] ?? L("phone.monitor.rowRemote")) : L("phone.monitor.rowLocal")
        }
    }

    private func orphanSelectionRow(windowID: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("phone.monitor.windowMissing"))
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                if let status = monitoringRowStatus(windowID: windowID) {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button(L("phone.monitor.group.remove")) { selectMonitoring(windowID: windowID, selected: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(PaperInk(scheme).elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sharesPage: some View {
        ScrollView {
            ReceivedSharesView(incomingURL: sharedInviteURL, refreshGeneration: shareRefreshGeneration)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .background(PaperInk(scheme).canvas)
        .tint(PaperInk(scheme).accent)
        .navigationTitle(L("phone.shares.title"))
        .refreshable { shareRefreshGeneration = UUID() }
    }

    private var monitorPage: some View {
        let windows = snapshot?.windows ?? []
        let showsControls = monitoringSelection.showsDisplayControls(availableWindowCount: windows.count, runningActivityCount: activeSessions.count)
        return ScrollView {
            VStack(spacing: 16) {
                StatusCard(message: message, busy: busy)
                if showsControls {
                    islandCard(windows)
                        .padding(20)
                        .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(PaperInk(scheme).divider, lineWidth: 0.5))
                        .padding(.horizontal, 16)
                }
                if !windows.isEmpty {
                    NavigationLink(value: PhoneRoute.widgets) {
                        PhoneLinkRow(
                            symbol: "square.grid.2x2",
                            title: L("phone.settings.widgets.title"),
                            detail: widgetSelection.isEmpty ? L("phone.widgets.summaryAutomatic") : L("phone.widgets.summaryCount", widgetSelection.count)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                } else if !showsControls {
                    ContentUnavailableView(L("phone.monitor.empty.title"), systemImage: "waveform.path", description: Text(L("phone.monitor.empty.description")))
                }
            }
            .padding(.bottom, 20)
        }
        .background(PaperInk(scheme).canvas)
        .tint(PaperInk(scheme).accent)
        .navigationTitle(L("phone.section.monitor"))
    }

    private var widgetsPage: some View {
        let windows = snapshot?.windows ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhoneWidgetPreviewStrip(snapshot: snapshot, fixedWindowIDs: widgetSelection,
                                        offline: refreshFreshness.isOffline)
                Divider()
                Text(L("phone.settings.widgets.priorityTitle")).font(.subheadline.weight(.semibold))
                widgetPriorityList(windows)
                Text(L("phone.settings.widgets.priorityHint"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("phone.settings.widgets.saveDefaults")) {
                    saveWidgetWindow()
                    widgetFeedback = message
                }
                .buttonStyle(.borderedProminent)
                .disabled(widgetSelection.isEmpty)
                if let widgetFeedback {
                    Label(widgetFeedback, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(PaperInk(scheme).accent)
                }
                Text(L("phone.settings.widgets.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(PaperInk(scheme).divider, lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(PaperInk(scheme).canvas)
        .tint(PaperInk(scheme).accent)
        .navigationTitle(L("phone.settings.widgets.title"))
        .onAppear { widgetFeedback = nil }
    }

    /// Ordered multi-select for the widget priority list: the first tap ranks
    /// highest; deselecting and re-adding moves a window to the end.
    private func widgetPriorityList(_ windows: [QuotaWindow]) -> some View {
        VStack(spacing: 8) {
            ForEach(windows, id: \.id) { window in
                let index = widgetSelection.firstIndex(of: window.id)
                PhoneQuotaOptionRow(
                    value: QuotaPresentation(window: window, now: .now, offline: refreshFreshness.isOffline),
                    selected: index != nil,
                    priorityIndex: index.map { $0 + 1 }
                ) {
                    if let index {
                        widgetSelection.remove(at: index)
                    } else if widgetSelection.count >= PairedEnvironment.maximumWidgetWindowIDs {
                        message = L("phone.error.widgetPriorityLimit")
                        widgetFeedback = message
                    } else {
                        widgetSelection.append(window.id)
                    }
                }
            }
        }
    }

    private func content(_ window: QuotaWindow) -> QuotaActivityAttributes.ContentState {
        func epoch(_ value: String?) -> Int64? { value.flatMap(QuotaRules.date).map { Int64($0.timeIntervalSince1970) } }
        let state = QuotaRules.state(window, now: .now)
        let displayState = refreshFreshness.isOffline && ![.locked, .authRequired, .unavailable].contains(state) ? "offline" : state.rawValue
        return .init(remainingBps: window.remainingBps, displayState: displayState,
                     observedAt: epoch(window.observedAt), staleAt: epoch(window.staleAt), resetsAt: epoch(window.window.resetsAt),
                     label: window.providerId + " · " + window.shortDisplayName + (window.quality == .reported ? "" : L("phone.activity.labelEstimate")), sequence: snapshot?.sourceSequence ?? 0)
    }
    #if DEBUG
    private func runFixtureActivityCheck() async {
        guard fixtureActivityCheck, !fixtureCheckRan, scenePhase == .active else { return }
        fixtureCheckRan = true
        displayIntent = SingleActivityDisplayIntentStore.load() ?? .init()
        MonitoringSelectionStore.save(monitoringSelection)
        if CommandLine.arguments.contains("--fixture-legacy-adopt"), let window = snapshot?.windows.first {
            await groupCoordinator.endAll(); await coordinator.endAllForRevocation()
            UserDefaults.standard.removeObject(forKey: SingleActivityDisplayIntentStore.key)
            try? coordinator.start(sessionID: UUID().uuidString, windowID: window.id,
                endsAt: Date.now.addingTimeInterval(3600), initial: content(window))
        } else if CommandLine.arguments.contains("--fixture-legacy-stop-crash"), let window = snapshot?.windows.first {
            // Explicit synthetic QA command simulates the crash window AFTER
            // durable Stop but BEFORE asynchronous legacy Activity removal.
            await groupCoordinator.endAll(); await coordinator.endAllForRevocation()
            try? coordinator.start(sessionID: UUID().uuidString, windowID: window.id,
                endsAt: Date.now.addingTimeInterval(3600), initial: content(window))
            displayIntent.stop(); persistDisplayIntent()
        } else {
            await reconcileActivitySelection()
        }
        await maintainLegacyActivities(identity: refreshIdentity)
        if CommandLine.arguments.contains("--fixture-show-once") { requestGroupDisplay() }
        else if CommandLine.arguments.contains("--fixture-stop") { stopGroupDisplay() }
        await displayQueue?.value
        syncActiveActivities()
        let groups = Activity<QuotaGroupActivityAttributes>.activities.filter { QuotaGroupActivityCoordinator.isRunning($0) }
        let receipt: [String: Any] = ["synthetic": true, "phase": displayIntent.phase.rawValue, "selectedWindowIDs": monitoringSelection.windowIDs,
            "groupCount": groups.count, "legacyCount": Activity<QuotaActivityAttributes>.activities.count,
            "legacyBps": Activity<QuotaActivityAttributes>.activities.map { $0.content.state.remainingBps ?? -1 },
            "rowCounts": groups.map { $0.attributes.descriptors.count },
            "rows": groups.map { $0.content.state.rows.map(\.windowID) },
            "remote": groups.map { $0.attributes.remoteUpdates }]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("single-activity-qa.json"), options: .atomic)

        }
    }
    #endif

    private func persistDisplayIntent() {
        if !fixtureRequested || fixtureActivityCheck { SingleActivityDisplayIntentStore.save(displayIntent) }
    }

    private func selectMonitoring(windowID: String, selected: Bool) {
        if selected {
            guard monitoringSelection.start(windowID: windowID) else { message = L("phone.error.maxWindows"); return }
        } else { monitoringSelection.stop(windowID: windowID) }
        if !fixtureRequested { MonitoringSelectionStore.save(monitoringSelection) }
        if displayIntent.wantsDisplay {
            if monitoringSelection.windowIDs.isEmpty { stopGroupDisplay() } else { requestGroupDisplay() }
        }
    }

    /// The only call site which requests a v2 Activity is this explicit foreground action.
    /// A queued restart captures intent, selection and source before cleanup suspends.
    private func requestGroupDisplay() {
        guard scenePhase == .active, !busy, !credentialTransition.isTransitioning, let initial = snapshot,
              monitoringSelection.windowIDs.contains(where: { id in initial.windows.contains { $0.id == id && $0.remainingBps != nil } }) else { return }
        let ids = monitoringSelection.windowIDs
        let id = UUID().uuidString
        let generation = displayIntent.begin(sessionID: id)
        persistDisplayIntent()
        groupRegistrar.markStopped()
        let source = initial.sourceDeviceId, epoch = initial.sourceEpoch, sync = syncGeneration
        let previous = displayQueue
        displayQueue = Task { @MainActor in
            await previous?.value
            guard displayIntent.permitsCreation(generation: generation, foreground: scenePhase == .active,
                sourceUnchanged: sync == syncGeneration && source == snapshot?.sourceDeviceId && epoch == snapshot?.sourceEpoch && !credentialTransition.isTransitioning && !busy,
                hasSelection: ids == monitoringSelection.windowIDs && !ids.isEmpty) else { return }
            // Stop/abandon is durable even when no group is visible yet. Legacy
            // cleanup is restricted to Ammo Activity types and retains widget data.
            await groupRegistrar.stop(abandon: true)
            await coordinator.endAllForRevocation()
            await groupCoordinator.endAll()
            guard displayIntent.permitsCreation(generation: generation, foreground: scenePhase == .active,
                sourceUnchanged: sync == syncGeneration && source == snapshot?.sourceDeviceId && epoch == snapshot?.sourceEpoch && !credentialTransition.isTransitioning && !busy,
                hasSelection: ids == monitoringSelection.windowIDs && !ids.isEmpty), let current = snapshot else { return }
            do {
                let projection = try ActivityGroupProjection(snapshot: current, windowIDs: ids, offline: refreshFreshness.isOffline)
                let endsAt = Int64(Date.now.addingTimeInterval(MonitoringSessionPolicy.systemActivityLifetime).timeIntervalSince1970)
                let options = ActivityDisplayOptions(showWindowName: showWindowName, showProgress: showProgress,
                    showObservationTime: true, displayStyle: QuotaDisplayStyle(storedValue: storedDisplayStyle),
                    compactStyle: ActivityCompactStyle(storedValue: compactStyle))
                func attributes(_ remote: Bool) -> QuotaGroupActivityAttributes {
                    .init(sessionID: id, sourceDeviceID: source, sourceEpoch: epoch, endsAt: endsAt,
                          descriptors: projection.descriptors, displayOptions: options, remoteUpdates: remote)
                }
                let wantsRemote = projection.supportsRemote && remoteUpdatesAvailable
                let remote = wantsRemote ? await groupRegistrar.prepare(attributes: attributes(true)) : false
                guard displayIntent.permitsCreation(generation: generation, foreground: scenePhase == .active,
                    sourceUnchanged: sync == syncGeneration && source == snapshot?.sourceDeviceId && epoch == snapshot?.sourceEpoch && !credentialTransition.isTransitioning && !busy,
                    hasSelection: ids == monitoringSelection.windowIDs && !ids.isEmpty) else {
                    if remote { await groupRegistrar.stop(abandon: true) }; return
                }
                try groupCoordinator.start(attributes: attributes(remote), content: projection.content)
                guard displayIntent.created(generation: generation) else { await groupCoordinator.end(sessionID: id); return }
                persistDisplayIntent()
                if remote { groupRegistrar.localCreated(sessionID: id) }
                syncActiveActivities()
                message = remote ? L("phone.monitor.startedRemote") : L("phone.monitor.startedLocal")
            } catch {
                if displayIntent.generation == generation { displayIntent.needsRestart(); persistDisplayIntent() }
                await groupRegistrar.endActivity(sessionID: id)
                message = L("phone.error.startUnavailable")
            }
        }
    }

    private func stopGroupDisplay() {
        displayIntent.stop(); persistDisplayIntent()
        groupRegistrar.markStopped()
        let previous = displayQueue
        displayQueue = Task { @MainActor in
            // End the local card before waiting for a network fence. The durable
            // tombstone and generation already invalidate suspended registrations.
            await groupCoordinator.endAll()
            await coordinator.endAllForRevocation()
            await previous?.value
            await groupRegistrar.stop()
            syncActiveActivities()
        }
    }
    private func inspect(_ text: String) {
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SyncError.configuration }
            let candidate: String
            if trimmed.contains("://") {
                candidate = trimmed
            } else {
                let request = trimmed.split(separator: "#", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
                candidate = "quotaisland://pair#" + request
            }
            guard let url = URL(string: candidate) else { throw SyncError.configuration }
            invitation = try PairingInvitation.parse(url)
            confirm = true
        }
        catch { message = L("phone.error.invalidPairingLink") }
    }
    private func handleDeepLink(_ url: URL) {
        if url.scheme == "quotaisland", url.host == "share" {
            sharedInviteURL = url
            section = .settings
            path = [.shares]
            return
        }
        if url.scheme == "quotaisland", url.host == "monitor" {
            section = .settings; path = [.monitor]; return
        }
        if url.scheme == "quotaisland", url.host == "window",
           let windowID = url.pathComponents.dropFirst().first, !windowID.isEmpty, windowID != "setup" {
            section = .settings
            path = [.monitor]
            // A card or widget link opens its controls only. Starting a new
            // display requires the explicit Show / Show again action.
            message = snapshot?.windows.contains(where: { $0.id == windowID }) == true || client != nil
                ? L("phone.deeplink.windowOpened") : L("phone.deeplink.connectFirst")
            return
        }
        section = .settings
        path = []
        inspect(url.absoluteString)
    }
    private func restoreTransportPreferences() {
        cfEnabled = PairedEnvironment.cfEnabled
        iCloudEnabled = PairedEnvironment.iCloudEnabled
        // Migrate only an existing explicitly paired installation.
        if UserDefaults(suiteName: PairedEnvironment.group)?.object(forKey: SyncPreferenceKeys.cloudflare) == nil,
           (try? PairedEnvironment.credentials()) != nil {
            cfEnabled = true
            PairedEnvironment.setSyncEnabled(true, key: SyncPreferenceKeys.cloudflare)
        }
        PhoneResetReminderSourcePolicy.reconcileTransportPreferences(coordinator: resetReminders,
            cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled)
    }
    private func legacySourcePredicate(identity: PhoneRefreshIdentity, scope: String) -> @MainActor (String) -> Bool {
        { windowID in
            cfEnabled && displayingCF && identity == refreshIdentity && !credentialTransition.isTransitioning &&
            currentCredentialScope == scope && monitoringSelection.windowIDs.contains(windowID) &&
            snapshot?.windows.contains(where: { $0.id == windowID }) == true
        }
    }
    private func configureActivityRegistrars(_ credentials: ViewerCredentials, identity: PhoneRefreshIdentity) async -> Bool {
        await PhoneActivityTransportPolicy.configure(
            isCurrent: { !Task.isCancelled && cfEnabled && identity == refreshIdentity && currentCredentialScope == RemoteActivityRegistrar.scope(credentials) },
            legacy: {
                await registrar.configure(credentials, sourceIsCurrent:
                    legacySourcePredicate(identity: identity, scope: RemoteActivityRegistrar.scope(credentials)))
            }, group: { await groupRegistrar.configure(credentials) })
    }
    private func disableActivityRegistrars(isCurrent: @escaping @MainActor () -> Bool) async {
        guard isCurrent() else { return }
        groupRegistrar.markDisabled(); registrar.markDisabled()
        await PhoneActivityTransportPolicy.disable(isCurrent: isCurrent,
            group: { await groupRegistrar.disable() }, legacy: { await registrar.disable() })
    }
    private func restore() async {
        restoreTransportPreferences()
        widgetSelection = (try? PairedEnvironment.widgetWindowIDs()) ?? []
        do {
            let credentials = try PairedEnvironment.credentials()
            connectedMode = SyncServiceCatalog.isOfficial(credentials.endpoint) ? .official : .selfHosted
            client = try PairedEnvironment.client(credentials)
            usageClient = cfEnabled ? (try? PairedEnvironment.usageClient(credentials)) : nil
            currentCredentialScope = RemoteActivityRegistrar.scope(credentials)
            // Background monitoring updates are always wanted; the only gate is
            // whether the paired service can accept push registrations.
            if cfEnabled {
                let identity = refreshIdentity
                if await configureActivityRegistrars(credentials, identity: identity) {
                    await groupRegistrar.recover()
                    if identity == refreshIdentity, cfEnabled { await alertRegistrar.configure(credentials) }
                }
            } else {
                let identity = refreshIdentity
                await groupRegistrar.restoreCleanup(credentials)
                guard identity == refreshIdentity, !cfEnabled else { syncReady = true; await refresh(); return }
                await disableActivityRegistrars(isCurrent: { identity == refreshIdentity && !cfEnabled })
                if identity == refreshIdentity, !cfEnabled { alertRegistrar.deconfigure() }
            }
            widgetSelection = (try? PairedEnvironment.widgetWindowIDs()) ?? []
            let cachedCF = cfEnabled ? (try await client?.cached()) : nil
            snapshot = await PairedEnvironment.cachedSelection(cf: cachedCF)
            displayingCF = snapshot != nil && snapshot?.snapshotId == cachedCF?.snapshotId
            tokenUsage = cfEnabled ? (try? await usageClient?.cached()) : nil
            usageStale = true
            if snapshot != nil { refreshFreshness.markCachedSnapshotLoaded() }
            if let windows = snapshot?.windows { try? PairedEnvironment.setWidgetWindowChoices(windows) }
        } catch VaultError.unavailable {
            connectedMode = nil
            try? PairedEnvironment.clearWidgetWindowChoices()
            claim = try? JSONDecoder().decode(PairingClaim.self, from: PairedEnvironment.vault.load("pending-claim"))
        } catch {
            // A locked Keychain does not revoke pairing or discard widget choices.
            connectedMode = nil
            claim = try? JSONDecoder().decode(PairingClaim.self, from: PairedEnvironment.vault.load("pending-claim"))
        }
        if !cfEnabled && !iCloudEnabled { await resetReminders.cancelAll() }
        else { await resetReminders.reconcile(snapshot: snapshot, verified: false, source: snapshot == nil ? nil : displayingCF ? .cloudflare : .iCloud) }
        syncReady = true
        await refresh()
    }
    private func beginPairing() async {
        guard cfEnabled, let invitation else { return }; busy = true; defer { busy = false }
        do {
            let next = try await PairingClient.claim(invitation, deviceName: "iPhone")
            try PairedEnvironment.vault.save(JSONEncoder().encode(next), account: "pending-claim")
            claim = next; link = ""
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: next.recipientPrivateKey).publicKey.rawRepresentation
            message = L("phone.pairing.verifyKey", Base64URL.encode(key))
        } catch { message = L("phone.error.pairingIncomplete") }
    }
    private func completePairing() async {
        guard cfEnabled, let claim, let transition = credentialTransition.begin() else { return }
        busy = true
        defer { credentialTransition.finish(transition); busy = false }
        let openingGeneration = syncGeneration
        var operationGeneration = openingGeneration
        do {
            let result = try await PairingClient.result(claim)
            guard !Task.isCancelled, openingGeneration == syncGeneration, cfEnabled else { return }
            guard let credentials = result else { message = L("phone.pairing.waitingApproval"); return }
            let pairedClient = try PairedEnvironment.client(credentials)
            let pairedUsage = try? PairedEnvironment.usageClient(credentials)
            guard try PhoneResetReminderSourcePolicy.commitCredentialReplacement(coordinator: resetReminders, save: {
                try PairedEnvironment.vault.save(JSONEncoder().encode(credentials), account: "viewer")
            }) else { message = resetReminders.status.text; return }
            let generation = UUID(); syncGeneration = generation; operationGeneration = generation
            // Swap both clients and their scope synchronously before cancellation
            // or registrar work suspends. Existing refreshes now fail identity.
            client = pairedClient; usageClient = pairedUsage
            currentCredentialScope = RemoteActivityRegistrar.scope(credentials)
            tokenUsage = nil; usageStale = true; usageMessage = nil
            let pairingIdentity = refreshIdentity
            await resetReminders.cancelAll()
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            displayIntent.stop(); persistDisplayIntent()
            await groupCoordinator.endAll()
            await coordinator.endAllForRevocation()
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            monitoringSelection = MonitoringSelection()
            if !fixtureRequested { MonitoringSelectionStore.save(monitoringSelection) }
            await disableActivityRegistrars(isCurrent: { !Task.isCancelled && generation == syncGeneration && pairingIdentity == refreshIdentity && cfEnabled })
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            alertRegistrar.deconfigure()
            // A new pairing must not inherit the previous account's intent catalog.
            try? PairedEnvironment.clearWidgetWindowChoices()
            try await PairingClient.acknowledge(claim)
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            try PairedEnvironment.vault.remove("pending-claim")
            currentCredentialScope = RemoteActivityRegistrar.scope(credentials)
            guard await configureActivityRegistrars(credentials, identity: pairingIdentity) else { return }
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            await alertRegistrar.configure(credentials)
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            self.claim = nil
            connectedMode = SyncServiceCatalog.isOfficial(credentials.endpoint) ? .official : .selfHosted
            let cf = try await pairedClient.refresh()
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            let selected = await PairedEnvironment.cachedSelection(cf: cf)
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            snapshot = selected
            displayingCF = snapshot != nil && snapshot?.snapshotId == cf?.snapshotId
            refreshFreshness.markRefreshSucceeded()
            if displayingCF {
                let offset = await pairedClient.clockOffset
                guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
                await resetReminders.reconcile(snapshot: snapshot, verified: true, clockOffset: offset, source: .cloudflare)
            }
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            if let windows = snapshot?.windows { try? PairedEnvironment.setWidgetWindowChoices(windows) }
            await refreshTokenUsage(generation: generation)
            guard !Task.isCancelled, generation == syncGeneration, pairingIdentity == refreshIdentity, cfEnabled else { return }
            message = L("phone.pairing.connected")
        } catch {
            guard !Task.isCancelled, operationGeneration == syncGeneration else { return }
            refreshFreshness.markRefreshFailed()
            message = L("phone.error.connectionIncomplete")
        }
    }

    private func acceptRotation() async {
        guard let next = proposedCredentials, let transition = credentialTransition.begin() else { return }
        defer { credentialTransition.finish(transition) }
        var operationGeneration = syncGeneration
        do {
            let nextClient = try PairedEnvironment.client(next)
            let nextUsage = try? PairedEnvironment.usageClient(next)
            guard try PhoneResetReminderSourcePolicy.commitCredentialReplacement(coordinator: resetReminders, save: {
                try PairedEnvironment.vault.save(JSONEncoder().encode(next), account: "viewer")
            }) else { message = resetReminders.status.text; return }
            let generation = UUID(); syncGeneration = generation; operationGeneration = generation
            client = nextClient; usageClient = nextUsage
            currentCredentialScope = RemoteActivityRegistrar.scope(next)
            tokenUsage = nil; usageStale = true
            proposedCredentials = nil; rotationConfirmation = nil
            let rotationIdentity = refreshIdentity
            await resetReminders.cancelAll()
            guard !Task.isCancelled, generation == syncGeneration, rotationIdentity == refreshIdentity else { return }
            guard await configureActivityRegistrars(next, identity: rotationIdentity) else { return }
            guard !Task.isCancelled, generation == syncGeneration, rotationIdentity == refreshIdentity else { return }
            await alertRegistrar.configure(next)
            guard !Task.isCancelled, generation == syncGeneration, rotationIdentity == refreshIdentity else { return }
            await groupRegistrar.recover()
            guard !Task.isCancelled, generation == syncGeneration, rotationIdentity == refreshIdentity else { return }
            credentialTransition.finish(transition)
            await refresh()
        } catch {
            guard !Task.isCancelled, operationGeneration == syncGeneration else { return }
            message = L("phone.error.keyUpdateNotSaved")
        }
    }
    private func saveWidgetWindow() {
        let ids = widgetSelection
        guard !ids.isEmpty else { return }
        guard ids.allSatisfy({ id in snapshot?.windows.contains(where: { $0.id == id }) == true }) else {
            message = L("phone.error.quotaUnavailable")
            return
        }
        if fixtureRequested {
            message = L("phone.fixture.widgetSelectionUpdated")
            return
        }
        do {
            try PairedEnvironment.setWidgetWindowIDs(ids)
            WidgetCenter.shared.reloadAllTimelines()
            message = L("phone.settings.widgets.saved", ids.count)
        } catch {
            message = L("phone.error.widgetSaveFailed")
        }
    }

    /// Widgets run in a separate process, so mirror the already-local display
    /// choice into the existing App Group preference suite. This stores no quota
    /// data and falls back to calibrated when the phone has not been paired yet.
    private func persistWidgetDisplayStyle(_ value: String) {
        guard !fixtureRequested, PairedEnvironment.group.hasPrefix("group.") else { return }
        UserDefaults(suiteName: PairedEnvironment.group)?.set(
            QuotaDisplayStyle(storedValue: value).rawValue,
            forKey: QuotaAppearanceKeys.displayStyle
        )
    }
    private func refresh() async {
        guard !Task.isCancelled, !fixtureRequested, syncReady else { return }
        guard !credentialTransition.isTransitioning else { refreshAgain = true; return }
        guard !busy else { refreshAgain = true; return }
        busy = true
        defer {
            busy = false
            if refreshAgain {
                refreshAgain = false
                // A foreground request queued while background work was busy
                // owns a fresh opportunity even when that background task expired.
                if scenePhase == .active { Task { await refresh() } }
            }
        }
        await reconcileActivitySelection()
        guard !Task.isCancelled, !credentialTransition.isTransitioning else { return }
        let generation = syncGeneration
        var acceptedIdentity = refreshIdentity
        let snapshotClient = client
        var iCloudValue: Snapshot?, cfValue: Snapshot?
        let previouslyCF = displayingCF
        var iCloudFailed = false, cfFailed = false, cfRevoked = false, iCloudRevoked = false
        var iCloudAccount: String?
        if iCloudEnabled {
            if iCloudClient == nil { iCloudClient = ICloudSnapshotSync() }
            do {
                iCloudAccount = try await iCloudClient?.accountIdentifier()
                guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
                iCloudValue = try await iCloudClient?.fetch(expectedAccount: iCloudAccount)
                guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
                if let iCloudValue, let iCloudAccount { try PairedEnvironment.iCloudCache().save(iCloudValue, accountID: iCloudAccount) }
                else { try PairedEnvironment.iCloudCache().clear() }
                iCloudMessage = iCloudValue == nil ? L("phone.icloud.waitingUpload") : L("phone.icloud.loadedLatest")
            } catch {
                guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
                iCloudFailed = true
                if let error = error as? ICloudSyncError {
                    switch error {
                    case .accountUnavailable, .accountMismatch:
                        iCloudRevoked = PhoneResetReminderSourcePolicy.acceptRevocation(source: .iCloud, coordinator: resetReminders,
                            identity: acceptedIdentity, currentIdentity: refreshIdentity,
                            transitioning: credentialTransition.isTransitioning, cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled)
                        iCloudAccount = nil
                        try? PairedEnvironment.iCloudCache().clear()
                    default: break
                    }
                }
                if let iCloudAccount { iCloudValue = try? PairedEnvironment.iCloudCache().load(accountID: iCloudAccount) }
                iCloudMessage = ICloudSyncFeedback.message(for: error).text + L("phone.icloud.localRetainedSuffix")
            }
        }
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        if cfEnabled, let snapshotClient {
            do { cfValue = try await snapshotClient.refresh() }
            catch TransportError.rejected(let code) where code == 401 || code == 403 {
                guard !Task.isCancelled else { return }
                cfFailed = true; cfRevoked = true
            } catch {
                guard !Task.isCancelled else { return }
                cfFailed = true
                cfValue = try? await snapshotClient.cached()
            }
        }
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        let selected = SyncSnapshotSelection.newest([cfValue, iCloudValue].compactMap { $0 })
        displayingCF = selected != nil && selected?.snapshotId == cfValue?.snapshotId
        snapshot = selected
        if (displayingCF && cfFailed) || (!displayingCF && iCloudFailed) {
            refreshFreshness.markRefreshFailed()
        } else { refreshFreshness.markRefreshSucceeded() }
        if PhoneResetReminderSourcePolicy.shouldCancel(source: resetReminders.source, eligibilitySource: resetReminders.eligibilitySource, cfRevoked: cfRevoked,
                iCloudRevoked: iCloudRevoked, cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled) {
            await resetReminders.cancelAll()
            guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        }
        let endedRemote = (!displayingCF || cfRevoked) ? await endRemoteMonitoring() : false
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        if displayingCF && !previouslyCF && !cfRevoked, let credentials = try? PairedEnvironment.credentials() {
            guard await configureActivityRegistrars(credentials, identity: acceptedIdentity) else { return }
            guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        }
        if cfRevoked {
            await disableActivityRegistrars(isCurrent: { !Task.isCancelled && generation == syncGeneration && acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) })
            guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
            alertRegistrar.deconfigure()
            client = nil
            acceptedIdentity = refreshIdentity // This refresh intentionally revoked its own client.
            usageClient = nil; tokenUsage = nil; usageStale = true
            usageMessage = L("tokenUsage.sync.revoked")
            try? PairedEnvironment.clearWidgetWindowChoices()
        } else if !displayingCF {
            // Another Mac's iCloud windows must never register against CF's workspace.
            // Background updates re-arm automatically the next time CF displays.
            await disableActivityRegistrars(isCurrent: { !Task.isCancelled && generation == syncGeneration && acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) })
            guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
            alertRegistrar.deconfigure()
        }
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        if (cfRevoked && previouslyCF) || (iCloudRevoked && !previouslyCF) ||
            (!cfEnabled && !iCloudEnabled) || (!previouslyCF && iCloudEnabled && !iCloudFailed && iCloudValue == nil && selected == nil) {
            await resetReminders.cancelAll()
        }
        let reminderOffset = displayingCF ? (await client?.clockOffset ?? 0) : 0
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        await resetReminders.reconcile(snapshot: selected, verified: !refreshFreshness.isOffline, clockOffset: reminderOffset, source: selected == nil ? nil : displayingCF ? .cloudflare : .iCloud)
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        try? PairedEnvironment.setWidgetWindowChoices(snapshot?.windows ?? [])
        if cfEnabled && displayingCF && !cfRevoked {
            registrar.refreshSource(scope: currentCredentialScope,
                sourceIsCurrent: legacySourcePredicate(identity: acceptedIdentity, scope: currentCredentialScope))
        }
        await maintainLegacyActivities(identity: acceptedIdentity)
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        for active in Activity<QuotaGroupActivityAttributes>.activities where QuotaGroupActivityCoordinator.isRunning(active) {
            let a = active.attributes
            guard displayIntent.phase == .active, displayIntent.sessionID == a.sessionID,
                  a.sourceDeviceID == snapshot?.sourceDeviceId, a.sourceEpoch == snapshot?.sourceEpoch,
                  a.descriptors.map(\.windowID) == monitoringSelection.windowIDs else {
                await groupCoordinator.end(sessionID: a.sessionID); continue
            }
            if !a.remoteUpdates, let snapshot,
               let projection = try? ActivityGroupProjection(snapshot: snapshot, windowIDs: a.descriptors.map(\.windowID),
                   previous: a.descriptors, offline: refreshFreshness.isOffline) {
                await groupCoordinator.updateLocal(sessionID: a.sessionID, content: projection.content)
            }
        }
        syncActiveActivities()
        if !fixtureRequested {
            // Every refresh re-extends the rolling push-registration window for
            // live sessions; each registration is bounded to +4h by the service.
            await groupRegistrar.recover()
        }
        if cfRevoked { message = L("phone.error.cfRevoked") }
        else if !cfEnabled && !iCloudEnabled { message = L("phone.status.syncDisabled") }
        else if iCloudFailed || cfFailed { message = L("phone.status.partialSync") }
        else { message = snapshot == nil ? L("phone.status.waitingUpload") : L("phone.status.loadedLatest") }
        if endedRemote { message += L("phone.status.remoteEndedSuffix") }
        if !cfRevoked { await refreshTokenUsage(generation: generation) }
        guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        if cfFailed && !cfRevoked && cfEnabled,
           let current = try? PairedEnvironment.credentials(),
           let proposal = try? await SourceRotation.proposedViewerCredentials(current) {
            guard !Task.isCancelled, generation == syncGeneration, acceptedIdentity.accepts(current: refreshIdentity, transitioning: credentialTransition.isTransitioning) else { return }
            proposedCredentials = proposal
            rotationConfirmation = RotationConfirmation(current: current, proposal: proposal)
            confirmRotation = true
        }
    }

    /// Token usage is an independent encrypted stream. Its failures never blank quotas.
    private func refreshTokenUsage(generation: UUID) async {
        guard !Task.isCancelled, generation == syncGeneration else { return }
        guard cfEnabled else {
            tokenUsage = nil; usageStale = true
            usageMessage = L("tokenUsage.sync.requiresWorker")
            return
        }
        guard let usageClient else {
            tokenUsage = nil; usageStale = true
            usageMessage = L(client == nil ? "tokenUsage.sync.requiresWorker" : "tokenUsage.sync.failed")
            return
        }
        do {
            let value = try await usageClient.refresh()
            guard !Task.isCancelled, generation == syncGeneration, cfEnabled else { return }
            tokenUsage = value.snapshot; usageStale = !value.verified
            usageMessage = !value.verified ? L("tokenUsage.sync.upgradeWorker") : value.snapshot == nil ? L("tokenUsage.sync.waiting") : nil
        } catch TransportError.rejected(let code) where code == 401 || code == 403 {
            guard !Task.isCancelled, generation == syncGeneration else { return }
            tokenUsage = nil; usageStale = true
            usageMessage = L("tokenUsage.sync.revoked")
        } catch {
            let cached = try? await usageClient.cached()
            guard !Task.isCancelled, generation == syncGeneration, cfEnabled else { return }
            tokenUsage = cached; usageStale = true
            usageMessage = L("tokenUsage.sync.failed")
        }
    }

    private func endRemoteMonitoring() async -> Bool {
        let legacy = Activity<QuotaActivityAttributes>.activities.filter { $0.pushToken != nil }
        let groups = Activity<QuotaGroupActivityAttributes>.activities.filter { $0.attributes.remoteUpdates }
        if !groups.isEmpty { displayIntent.needsRestart(); persistDisplayIntent(); await groupRegistrar.stop(abandon: true) }
        for activity in groups { await groupCoordinator.end(sessionID: activity.attributes.sessionID) }
        for activity in legacy { await coordinator.end(sessionID: activity.attributes.sessionID) }
        return !legacy.isEmpty || !groups.isEmpty
    }

    private func maintainLegacyActivities(identity: PhoneRefreshIdentity) async {
        let records = Activity<QuotaActivityAttributes>.activities.filter { QuotaActivityCoordinator.isRunning($0) }
            .map { LegacyActivityMaintenanceRecord(sessionID: $0.attributes.sessionID,
                windowID: $0.attributes.windowID, remoteUpdates: $0.pushToken != nil) }
        let eligible = Set(monitoringSelection.windowIDs).intersection(Set(snapshot?.windows.map(\.id) ?? []))
        await SingleActivityRecoveryPolicy.maintainLegacy(records: records, eligibleWindowIDs: eligible,
            isCurrent: { !Task.isCancelled && identity == refreshIdentity && !credentialTransition.isTransitioning },
            hasRecordedIntent: { SingleActivityDisplayIntentStore.load() != nil },
            canRenewRemote: { cfEnabled && displayingCF && registrar.available },
            updateLocal: { sessionID, windowID in
                guard let window = snapshot?.windows.first(where: { $0.id == windowID }),
                      let activity = Activity<QuotaActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }),
                      QuotaActivityCoordinator.isRunning(activity), activity.pushToken == nil else { return }
                let value = content(window)
                await coordinator.update(sessionID: sessionID, content: value,
                    staleAt: value.staleAt.map { Date(timeIntervalSince1970: Double($0)) })
            }, renewRemote: { sessionID, windowID in
                await registrar.recover(sessionID: sessionID, windowID: windowID,
                    isCurrent: { !Task.isCancelled && identity == refreshIdentity && !credentialTransition.isTransitioning && cfEnabled && displayingCF })
            }, retire: { sessionID in await coordinator.end(sessionID: sessionID) })
    }

    private func syncActiveActivities() {
        var running = Dictionary(uniqueKeysWithValues: Activity<QuotaActivityAttributes>.activities
            .filter { QuotaActivityCoordinator.isRunning($0) }.map { ($0.attributes.sessionID, $0.attributes.windowID) })
        let groups = Activity<QuotaGroupActivityAttributes>.activities.filter { QuotaGroupActivityCoordinator.isRunning($0) }
        for activity in groups {
            for row in activity.attributes.descriptors { running[activity.attributes.sessionID + ":" + row.windowID] = row.windowID }
        }
        activeSessions = running
        if displayIntent.phase == .active {
            displayIntent.reconcile(runningSessionIDs: Set(groups.map { $0.attributes.sessionID }))
            persistDisplayIntent()
        }
    }

    /// Loading saved selections or a system-ended card never requests an activity.
    /// Incomplete creates become explicit restart, with remote abandonment handled
    /// by the scope-bound registrar before any new group registration.
    private func reconcileActivitySelection() async {
        guard !fixtureRequested || fixtureActivityCheck else { return }
        if !monitoringSelectionLoaded {
            monitoringSelectionLoaded = true
            syncActiveActivities()
            monitoringSelection = MonitoringSelection.restored(
                savedWindowIDs: MonitoringSelectionStore.windows(), runningWindowIDs: activeSessions.values)
            MonitoringSelectionStore.save(monitoringSelection)
            let savedIntent = SingleActivityDisplayIntentStore.load()
            displayIntent = savedIntent ?? .init()
            displayIntent.reconcile(runningSessionIDs: Set(Activity<QuotaGroupActivityAttributes>.activities
                .filter { QuotaGroupActivityCoordinator.isRunning($0) }.map { $0.attributes.sessionID }))
            // Preserve no-record legacy adoption across relaunches until an
            // explicit v2 action records intent. Every recorded intent retires v1.
            if savedIntent != nil || Activity<QuotaActivityAttributes>.activities.isEmpty { persistDisplayIntent() }
        }
        for activity in Activity<QuotaActivityAttributes>.activities
            where SingleActivityRecoveryPolicy.shouldEndLegacyActivity(savedIntent: SingleActivityDisplayIntentStore.load(),
                selected: !monitoringSelection.shouldEndExistingActivity(windowID: activity.attributes.windowID)) {
            await coordinator.end(sessionID: activity.attributes.sessionID)
        }
        for activity in Activity<QuotaGroupActivityAttributes>.activities {
            let a = activity.attributes
            if displayIntent.phase != .active || displayIntent.sessionID != a.sessionID ||
                a.descriptors.map(\.windowID) != monitoringSelection.windowIDs {
                await groupCoordinator.end(sessionID: a.sessionID)
            }
        }
        syncActiveActivities()
    }

}

/// In-app, multi-size widget previews drawn by the widget extension's own view
/// code, so what the user sees here matches the installed widget instead of
/// describing it in text. Sizes approximate a 393-pt device; the Home Screen
/// rendering stays authoritative.
private struct PhoneWidgetPreviewStrip: View {
    let snapshot: Snapshot?
    let fixedWindowIDs: [String]
    let offline: Bool
    @Environment(\.colorScheme) private var scheme

    private var projection: WidgetProjection {
        WidgetProjection(snapshot: snapshot, entryDate: .now, offline: offline,
                         fixedWindowIDs: fixedWindowIDs, requiresWindowSelection: true)
    }

    @State private var selectedFamily: WidgetFamilyKind = .systemMedium

    var body: some View {
        let palette = PaperInk(scheme)
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("phone.settings.widgets.title"), selection: $selectedFamily) {
                Text(L("phone.settings.widgets.preview.small")).tag(WidgetFamilyKind.systemSmall)
                Text(L("phone.settings.widgets.preview.medium")).tag(WidgetFamilyKind.systemMedium)
                Text(L("phone.settings.widgets.preview.lockscreen")).tag(WidgetFamilyKind.accessoryRectangular)
            }
            .pickerStyle(.segmented)
            Group {
                switch selectedFamily {
                case .systemSmall:
                    widgetChrome(width: 150, height: 150) {
                        QuotaWidgetView(projection: projection, family: .systemSmall)
                    }
                case .systemMedium:
                    widgetChrome(height: 150) {
                        QuotaWidgetView(projection: projection, family: .systemMedium)
                    }
                default:
                    lockPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Text(L("phone.settings.widgets.preview.hint"))
                .font(.caption2).foregroundStyle(palette.muted)
        }
    }

    /// Preview one rectangular Lock Screen widget containing both selected quotas.
    private var lockPanel: some View {
        QuotaWidgetView(projection: projection, family: .accessoryRectangular)
            .frame(width: 126, height: 40)
            .environment(\.colorScheme, .dark)
            .padding(12)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(height: 150)
    }

    private func widgetChrome(width: CGFloat? = nil, height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        let palette = PaperInk(scheme)
        return content()
            .padding(13)
            .frame(width: width, height: height, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(palette.elevated, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(palette.divider, lineWidth: 0.5))
    }
}

/// A tappable card that opens a secondary page; styled like the settings cards.
private struct PhoneLinkRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PaperInk(scheme)
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(palette.ink)
                Text(detail).font(.caption).foregroundStyle(palette.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.divider, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// Selection changes the independent rows inside the single shared card.
private struct PhoneLockScreenSelectionRow: View {
    let value: QuotaPresentation
    @Binding var isOn: Bool
    var statusText: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let palette = PaperInk(scheme)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(value.window.shortDisplayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(value.window.accountAlias)
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                if let statusText {
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .lineLimit(2)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                Text(value.number)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                if let observedAt = value.window.observedAt.flatMap(QuotaRules.date) {
                    Text(L("widget.activity.observed.short", observedAt.formatted(date: .omitted, time: .shortened)))
                        .font(.caption2).foregroundStyle(palette.muted)
                }
            }
            VStack(spacing: 4) {
                Button(L(isOn ? "phone.monitor.group.remove" : "phone.monitor.group.select")) { isOn.toggle() }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel(L(isOn ? "phone.monitor.group.remove" : "phone.monitor.group.select") + " · " + value.window.shortDisplayName)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isOn ? palette.accent.opacity(0.08) : palette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isOn ? palette.accent : palette.divider, lineWidth: isOn ? 1.2 : 0.5))
    }
}

private struct StatusCard: View {
    let message: String
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "info.circle") }
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}

private struct PhoneLanguageSettings: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("phone.settings.language.title"), systemImage: "globe").font(.headline)
            Picker(L("phone.settings.language.title"), selection: Binding(
                get: { L10n.currentSetting },
                set: { language in
                    L10n.setLanguage(language)
                    // Widget entries render in the extension process; push the new language.
                    WidgetCenter.shared.reloadAllTimelines()
                })) {
                ForEach(QuotaLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            Text(L("phone.settings.language.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PhonePairingSetup: View {
    @Binding var link: String
    let invitation: PairingInvitation?
    let claim: PairingClaim?
    let busy: Bool
    let inspect: () -> Void
    let onScan: (String) -> Void
    let onScanUnavailable: (String) -> Void
    let requestPairing: () -> Void
    let complete: () -> Void
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("phone.pairing.setupTitle")).font(.title2.bold())
            Text(L("phone.pairing.setupIntro"))
                .font(.caption).foregroundStyle(.secondary)
            PhonePairingStep(number: 1, title: L("phone.pairing.step1.title"), detail: L("phone.pairing.step1.detail"), active: invitation == nil && claim == nil)
            HStack(spacing: 10) {
                TextField(L("phone.pairing.linkPlaceholder"), text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                Button { scanning = true } label: {
                    Image(systemName: "qr.code.viewfinder")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L("phone.pairing.scan"))
            }
            Button(L("phone.pairing.checkSource"), action: inspect).disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            PhonePairingStep(number: 2, title: L("phone.pairing.step2.title"), detail: invitation.map { L("phone.pairing.step2.hostFingerprint", $0.endpoint.host ?? $0.endpoint.absoluteString, $0.fingerprint) } ?? L("phone.pairing.step2.detail"), active: invitation != nil && claim == nil)
            if invitation != nil && claim == nil { Button(L("phone.pairing.sendRequest"), action: requestPairing).disabled(busy) }

            PhonePairingStep(number: 3, title: L("phone.pairing.step3.title"), detail: claim == nil ? L("phone.pairing.step3.pending") : L("phone.pairing.step3.sent"), active: claim != nil)
            PhonePairingStep(number: 4, title: L("phone.pairing.step4.title"), detail: L("phone.pairing.step4.detail"), active: claim != nil)
            if claim != nil { Button(L("phone.pairing.complete"), action: complete).disabled(busy) }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .sheet(isPresented: $scanning) {
            PairingScannerView(
                onPayload: { payload in scanning = false; onScan(payload) },
                onUnavailable: { reason in scanning = false; onScanUnavailable(reason) }
            )
            .ignoresSafeArea()
        }
    }
}

private struct PhonePairingStep: View {
    let number: Int
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 26, height: 26)
                .foregroundStyle(active ? .white : .primary)
                .background(active ? Color.accentColor : Color.primary.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// Persist only window selection, never a restart command. Legacy desired-window
/// IDs migrate as selections and cannot trigger automatic foreground/background starts.
enum MonitoringSelectionStore {
    private static let key = "quota.monitor.desiredWindows"
    private static var defaults: UserDefaults? {
        guard PairedEnvironment.group.hasPrefix("group.") else { return nil }
        return UserDefaults(suiteName: PairedEnvironment.group)
    }
    static func windows() -> [String]? { defaults?.stringArray(forKey: key) }
    static func save(_ selection: MonitoringSelection) {
        // Keep an empty value as a tombstone: a card awaiting async removal
        // must not be adopted again if the app relaunches after Stop.
        defaults?.set(selection.windowIDs, forKey: key)
    }
}

private struct RotationConfirmation {
    let origin: String
    let oldFingerprint: String
    let newFingerprint: String

    init(current: ViewerCredentials, proposal: ViewerCredentials) {
        origin = "\(current.trust.deviceID) · \(current.endpoint.host ?? current.endpoint.absoluteString)"
        oldFingerprint = Self.fingerprint(current.trust.publicKey)
        newFingerprint = Self.fingerprint(proposal.trust.publicKey)
    }

    private static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }
}
