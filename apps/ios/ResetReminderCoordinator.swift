import Foundation
import Combine
import UserNotifications
import QuotaCore
import QuotaStore

@MainActor
public protocol ResetReminderNotificationClient {
    func authorize(requestIfNeeded: Bool) async throws -> Bool
    func pendingIDs() async -> Set<String>
    /// Queue an OS query immediately; await its result separately.
    func startPendingQuery() -> Task<Set<String>, Never>
    func add(_ request: ResetReminderRequest) async throws
    func remove(ids: [String])
}

/// Shared OS permission; this helper never registers remote notification tokens.
public enum LocalNotificationAuthorization {
    public static func authorize(requestIfNeeded: Bool, options: UNAuthorizationOptions = [.alert, .sound], center: UNUserNotificationCenter = .current()) async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            return requestIfNeeded ? try await center.requestAuthorization(options: options) : false
        case .denied: return false
        @unknown default: return false
        }
    }
}

/// Fixture, SwiftPM and XCTest processes must not touch a native user's ledger
/// or notifications, including tests hosted inside the production app bundle.
enum ResetReminderRuntime {
    static func allowsPersistentEffects(bundleExtension: String, bundleIdentifier: String?, arguments: [String],
                                        environment: [String: String], testingRuntime: Bool = false) -> Bool {
        bundleExtension == "app" && bundleIdentifier != nil && !arguments.contains("--fixture") && !testingRuntime &&
            !environment.keys.contains { $0.uppercased().hasPrefix("XCTEST") || $0 == "SWIFT_TESTING_ENABLED" }
    }
    static var isNativeApplication: Bool {
        allowsPersistentEffects(bundleExtension: Bundle.main.bundleURL.pathExtension,
            bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            testingRuntime: NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil)
    }
}

@MainActor
public struct SystemResetReminderNotifications: ResetReminderNotificationClient {
    public init() {}
    public func authorize(requestIfNeeded: Bool) async throws -> Bool {
        guard ResetReminderRuntime.isNativeApplication else { return false }
        return try await LocalNotificationAuthorization.authorize(requestIfNeeded: requestIfNeeded)
    }
    public func pendingIDs() async -> Set<String> {
        guard ResetReminderRuntime.isNativeApplication else { return [] }
        return Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
    }
    public func startPendingQuery() -> Task<Set<String>, Never> {
        guard ResetReminderRuntime.isNativeApplication else { return Task { [] } }
        let (stream, continuation) = AsyncStream<Set<String>>.makeStream()
        // The caller chooses whether this observation precedes or follows a
        // removal request. Removal itself has no completion callback.
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            continuation.yield(Set(requests.map(\.identifier))); continuation.finish()
        }
        return Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? []
        }
    }
    public func add(_ request: ResetReminderRequest) async throws {
        guard ResetReminderRuntime.isNativeApplication else { throw CocoaError(.featureUnsupported) }
        let content = UNMutableNotificationContent()
        content.title = request.title; content.body = request.body; content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: ResetReminderPolicy.utcComponents(for: request.fireAt), repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }
    public func remove(ids: [String]) {
        guard ResetReminderRuntime.isNativeApplication else { return }
        let owned = ids.filter { $0.hasPrefix(ResetReminderPolicy.prefix) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: owned)
        center.removeDeliveredNotifications(withIdentifiers: owned)
    }
}

@MainActor
public final class VolatileResetReminderStorage: ResetReminderStorage {
    private var data: Data?
    public init() {}
    public func read() throws -> Data? { data }
    public func write(_ data: Data) throws { self.data = data }
}

/// Persist only preferences, hashed identities and forecast times. Snapshot
/// plaintext, aliases, credentials and notification bodies never enter this file.
@MainActor
public protocol ResetReminderStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

@MainActor
public struct FileResetReminderStorage: ResetReminderStorage {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() throws -> Data? {
        do { return try PrivateFile.read(url, maxBytes: 1_048_576) }
        catch StoreError.unavailable { return nil }
    }
    public func write(_ data: Data) throws { try PrivateFile.write(data, to: url) }

}

public enum ResetReminderSource: String, Codable, Sendable { case local, cloudflare, iCloud }

public enum ResetReminderStartupPolicy {
    /// Local account intent must be applied before unrelated startup awaits.
    /// Missing/unreadable configuration cannot establish any enabled account.
    @MainActor
    public static func restoreAccountIntent(coordinator: ResetReminderCoordinator, now: Date = .now,
                                           loadAccountKeys: () throws -> Set<String>) {
        coordinator.updateAllowedAccounts((try? loadAccountKeys()) ?? [], now: now)
    }

    /// Accepted configuration and reminder filtering share one synchronous
    /// boundary, including drafts, cleanup writes and durable rollbacks.
    @MainActor
    public static func commitAccountIntent(coordinator: ResetReminderCoordinator, accountKeys: Set<String>,
                                          now: Date = .now, save: () throws -> Void) throws {
        do { try save() }
        catch {
            // An atomic rename may succeed before directory fsync throws.
            // Neither the old nor proposed intent is established by failure.
            coordinator.updateAllowedAccounts([], now: now)
            throw error
        }
        coordinator.updateAllowedAccounts(accountKeys, now: now)
    }
}

@MainActor
public final class ResetReminderCoordinator: ObservableObject {
    private struct Record: Codable {
        var cycleID, accountKey, windowKey: String
        var leadMinutes: Int
        var fireAt, resetsAt, observedAt: Date
        var accepted: Bool
    }
    private struct State: Codable {
        var settings = ResetReminderSettings()
        var scope: String?
        var source: ResetReminderSource?
        var sequence: Int64 = -1
        var records: [String: Record] = [:]
        var cancelledRecords: [String: Record]?
        var issuedCycles: [String: Date] = [:]
        var windowObservations: [String: Date] = [:]
        var clockHighWater: Date?
        var credentialReplacementIDs: Set<String>?
        var allowedAccounts: Set<String>?
    }
    @Published public private(set) var settings = ResetReminderSettings()
    @Published public private(set) var status = LocalizedStatus("resetReminder.off")
    private var state = State()
    private var readable = true
    private let storage: any ResetReminderStorage
    private let client: any ResetReminderNotificationClient
    private let clock: @MainActor () -> Date
    public var source: ResetReminderSource? { state.source }
    /// The owner of cached or queued snapshot eligibility is visible before
    /// scheduling persists its provenance, including while reminders are off.
    public var eligibilitySource: ResetReminderSource? { latestSnapshot == nil ? nil : latestSource }
    private var generation = UUID()
    private var authorizationGeneration = UUID()
    private var tail: Task<Void, Never>?
    private var latestSnapshot: Snapshot?
    private var latestVerified = false
    private var latestClockOffset: TimeInterval = 0
    private var latestSource: ResetReminderSource?
    private var lastKnownPending = Set<String>()

    public static func local() -> ResetReminderCoordinator {
        // Unbundled tests/CLI and explicit fixtures never read a user's ledger.
        if !ResetReminderRuntime.isNativeApplication {
            return ResetReminderCoordinator(storage: VolatileResetReminderStorage())
        }
        #if os(macOS)
        // Reuse the collector's owner-only data directory. The historical Ammo
        // UI directory may be 0755; never chmod another feature's storage.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaIsland", isDirectory: true)
        #else
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ammo", isDirectory: true)
        #endif
        return ResetReminderCoordinator(storage: FileResetReminderStorage(url: directory.appendingPathComponent("reset-reminders-v1.json")))
    }

    public init(storage: any ResetReminderStorage, client: (any ResetReminderNotificationClient)? = nil, clock: @escaping @MainActor () -> Date = { .now }) {
        self.storage = storage; self.client = client ?? SystemResetReminderNotifications(); self.clock = clock
        do {
            if let data = try storage.read() {
                state = try JSONDecoder().decode(State.self, from: data)
                guard state.settings.isValid, state.records.count + (state.cancelledRecords?.count ?? 0) <= 48, state.issuedCycles.count <= 2048, state.windowObservations.count <= 2048,
                      Set(state.issuedCycles.keys).union(state.records.values.map(\.cycleID))
                        .union((state.cancelledRecords ?? [:]).values.map(\.cycleID)).count <= 2048,
                      state.records.keys.allSatisfy({ $0.hasPrefix(ResetReminderPolicy.prefix) }),
                      (state.cancelledRecords ?? [:]).keys.allSatisfy({ $0.hasPrefix(ResetReminderPolicy.prefix) }),
                      (state.credentialReplacementIDs?.count ?? 0) <= ResetReminderPolicy.maximumPending,
                      (state.credentialReplacementIDs ?? []).allSatisfy({ $0.hasPrefix(ResetReminderPolicy.prefix) }) else { throw CocoaError(.fileReadCorruptFile) }
                settings = state.settings
                if settings.enabled { status = LocalizedStatus("resetReminder.waiting") }
            }
        } catch { readable = false; state = State(); status = LocalizedStatus("resetReminder.storageError") }
        let recoveredCancelled = state.cancelledRecords ?? [:]
        if let ids = state.credentialReplacementIDs {
            self.client.remove(ids: Array(ids))
            invalidateSource(now: clock())
        }
        if !recoveredCancelled.isEmpty { enqueueCancellation(records: recoveredCancelled, now: clock()) }
    }

    /// Explicit as-of dates remain useful in tests. The injected clock advances
    /// that date across suspension instead of freezing scheduling eligibility.
    private func advancingTime(from date: Date, beganAt: Date) -> Date {
        date.addingTimeInterval(clock().timeIntervalSince(beganAt))
    }

    @discardableResult
    private func persist(now: Date = .now) -> Bool {
        guard readable else { return failStorage() }
        preserveUnresolvedCycles(records: state.records, now: now)
        preserveUnresolvedCycles(records: state.cancelledRecords ?? [:], now: now)
        state.clockHighWater = max(state.clockHighWater ?? now, now)
        // Past resets cannot produce a future trigger. Keep every active cycle;
        // never discard an active marker just to admit another notification.
        state.issuedCycles = state.issuedCycles.filter { $0.value > now }
        let activeWindows = Set(state.records.values.map(\.windowKey))
        state.windowObservations = state.windowObservations.filter { activeWindows.contains($0.key) || $0.value > now.addingTimeInterval(-30 * 86400) }
        do { try storage.write(JSONEncoder().encode(state)); settings = state.settings; return true }
        catch { return failStorage() }
    }

    private func failStorage() -> Bool {
        readable = false; generation = UUID(); authorizationGeneration = UUID()
        state.settings.enabled = false; settings = state.settings
        // A failed write may follow cancellation of only part of the batch.
        // Request cleanup of every known owned ID, retaining cycle evidence.
        let ids = Set(state.records.keys).union(state.cancelledRecords?.keys.map { $0 } ?? [])
            .union(state.credentialReplacementIDs ?? []).union(lastKnownPending).filter { $0.hasPrefix(ResetReminderPolicy.prefix) }
        client.remove(ids: Array(ids))
        status = LocalizedStatus("resetReminder.storageError")
        return false
    }

    private func preserveUnresolvedCycles(records: [String: Record], now: Date) {
        // Preparation may precede an accepted add whose completion is lost.
        // Missing pending evidence cannot distinguish rejection from delivery;
        // suppress unresolved attempts until reset or confirmed cancellation.
        for record in records.values where !record.accepted && record.resetsAt > now {
            state.issuedCycles[record.cycleID] = record.resetsAt
        }
    }

    private func clockIsTrusted(at now: Date, offset: TimeInterval) -> Bool {
        abs(offset) <= 120 && (state.clockHighWater.map { now >= $0.addingTimeInterval(-120) } ?? true)
    }

    private func releaseCancelledCycles(records: [String: Record], before: Set<String>, after: Set<String>,
                                        evidenceAt: Date, now: Date, clockTrusted: Bool) {
        preserveUnresolvedCycles(records: records, now: now)
        guard clockTrusted, clockIsTrusted(at: now, offset: 0), now >= evidenceAt else { return }
        for (id, record) in records where before.contains(id) && !after.contains(id) && record.fireAt > now {
            state.issuedCycles.removeValue(forKey: record.cycleID)
        }
    }

    private func resolveCleanupRecords(_ records: [String: Record], after: Set<String>) {
        for (id, record) in records where state.cancelledRecords?[id]?.cycleID == record.cycleID {
            if after.contains(id) { lastKnownPending.insert(id) }
            else {
                state.cancelledRecords?.removeValue(forKey: id)
                lastKnownPending.remove(id)
            }
        }
    }

    private func enqueueCancellation(records: [String: Record], now: Date) {
        guard !records.isEmpty else { return }
        let beganAt = clock()
        let pendingQuery = client.startPendingQuery() // Presence alone is not cancellation proof.
        var cancelled = state.cancelledRecords ?? [:]
        for (id, record) in records { cancelled[id] = record; state.records.removeValue(forKey: id) }
        state.cancelledRecords = cancelled
        client.remove(ids: Array(records.keys))
        if readable { _ = persist(now: now) }
        let predecessor = tail
        tail = Task { @MainActor [weak self] in
            let before = await pendingQuery.value
            let evidenceAt = self?.advancingTime(from: now, beganAt: beganAt) ?? now
            // Late adds finish before observing whether the OS still has IDs.
            // This is also an unconditional barrier for rapid disable/enable.
            await predecessor?.value
            if let self {
                let after = await self.client.pendingIDs()
                let current = self.advancingTime(from: now, beganAt: beganAt)
                let unresolved = (self.state.cancelledRecords ?? [:]).filter { id, record in
                    records[id]?.cycleID == record.cycleID
                }
                self.releaseCancelledCycles(records: unresolved, before: before, after: after,
                    evidenceAt: max(now, evidenceAt), now: current, clockTrusted: abs(self.latestClockOffset) <= 120)
                self.resolveCleanupRecords(unresolved, after: after)
                if self.readable { _ = self.persist(now: current) }
            }
        }
    }

    /// Direct replacement/cancellation uses the same before/after evidence as
    /// queued cancellation. No stale pending result can bypass suppression.
    private func cancelRecords(_ records: [String: Record], before: Set<String>, evidenceAt: Date,
                               time: @MainActor () -> Date, clockTrusted: Bool, ticket: UUID) async -> Bool {
        guard !records.isEmpty else { return true }
        let began = time()
        preserveUnresolvedCycles(records: records, now: began)
        var cancelled = state.cancelledRecords ?? [:]
        for (id, record) in records { cancelled[id] = record }
        state.cancelledRecords = cancelled
        client.remove(ids: Array(records.keys))
        for id in records.keys { state.records.removeValue(forKey: id) }
        guard persist(now: began) else { return false }
        let after = await client.pendingIDs()
        let current = time()
        guard generation == ticket else { return false }
        lastKnownPending = after
        releaseCancelledCycles(records: records, before: before, after: after,
            evidenceAt: max(evidenceAt, began), now: current, clockTrusted: clockTrusted)
        resolveCleanupRecords(records, after: after)
        return persist(now: current)
    }

    private func removeKnownImmediately(now: Date) {
        enqueueCancellation(records: state.records, now: now)
    }

    /// Invalidate before authorization suspends: a later Disable always wins.
    public func setEnabled(_ enabled: Bool, now: Date = .now) async {
        let beganAt = clock()
        let ticket = UUID(); authorizationGeneration = ticket; generation = UUID()
        if !enabled { removeKnownImmediately(now: now) }
        guard readable else { await clearOwned(ticket: generation); return }
        if enabled {
            do {
                let authorized = try await client.authorize(requestIfNeeded: true)
                guard ticket == authorizationGeneration else { return }
                guard authorized else { status = LocalizedStatus("resetReminder.denied"); return }
            } catch { if ticket == authorizationGeneration { status = LocalizedStatus("resetReminder.unavailable") }; return }
        }
        guard ticket == authorizationGeneration else { return }
        let now = advancingTime(from: now, beganAt: beganAt)
        let operation = UUID(); generation = operation
        state.settings.enabled = enabled
        guard persist(now: now) else { await clearOwned(ticket: operation, now: now); return }
        status = LocalizedStatus(enabled ? "resetReminder.waiting" : "resetReminder.off")
        if enabled { await reconcile(snapshot: latestSnapshot, verified: latestVerified, now: now, clockOffset: latestClockOffset, source: latestSource) }
        else { await clearOwned(ticket: operation, now: now) }
    }

    public func setLeadMinutes(_ minutes: Int, now: Date = .now) async {
        guard ResetReminderSettings.leadChoices.contains(minutes) else { return }
        authorizationGeneration = UUID()
        let ticket = UUID(); generation = ticket; state.settings.leadMinutes = minutes
        guard persist(now: now) else { await clearOwned(ticket: generation, now: now); return }
        guard generation == ticket else { return }
        await reconcile(snapshot: latestSnapshot, verified: latestVerified, now: now, clockOffset: latestClockOffset, source: latestSource)
    }

    /// Mac connection configuration is authoritative even when no new snapshot
    /// arrives. nil means the phone does not filter provider account selection.
    public func updateAllowedAccounts(_ accounts: Set<String>?, now: Date? = nil) {
        let now = now ?? clock()
        let disallowed = state.records.filter { _, record in accounts.map { !$0.contains(record.accountKey) } ?? false }
        guard accounts != state.allowedAccounts || !disallowed.isEmpty else { return }
        authorizationGeneration = UUID()
        let ticket = UUID(); generation = ticket; state.allowedAccounts = accounts
        enqueueCancellation(records: disallowed, now: now)
        let saved = persist(now: now)
        Task { @MainActor [weak self] in
            guard let self, self.generation == ticket else { return }
            if saved { await self.reconcile(snapshot: self.latestSnapshot, verified: self.latestVerified, now: now, clockOffset: self.latestClockOffset, source: self.latestSource) }
            else { await self.clearOwned(ticket: ticket) }
        }
    }

    /// Source revocation/replacement cancels old forecasts without changing the
    /// user's per-device opt-in. Queued adds cannot survive this generation.
    @discardableResult
    public func invalidateSource(now: Date = .now) -> Bool {
        let beganAt = clock()
        authorizationGeneration = UUID(); generation = UUID(); latestSnapshot = nil; latestVerified = false; latestSource = nil
        removeKnownImmediately(now: now)
        state.records.removeAll(); state.windowObservations.removeAll(); state.scope = nil; state.source = nil; state.sequence = -1
        let saved = readable && persist(now: now)
        let predecessor = tail
        // Cleanup is a barrier, even if a new source arrives while pendingIDs
        // suspends. New scheduling waits behind it and cannot be removed by it.
        tail = Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = await self.client.pendingIDs()
            let current = self.advancingTime(from: now, beganAt: beganAt)
            self.client.remove(ids: Array(pending.filter { $0.hasPrefix(ResetReminderPolicy.prefix) }))
            if self.readable { _ = self.persist(now: current) }
            await predecessor?.value // Barrier prevents cleanup removing a new source.
        }
        return saved
    }

    /// Persist a restart-visible invalidation before the host replaces viewer
    /// credentials. Never commit new credentials when either write fails.
    public func prepareCredentialReplacement(now: Date = .now) -> Bool {
        guard readable else { return failStorage() }
        let ids = Set(state.records.keys).union(state.cancelledRecords?.keys.map { $0 } ?? [])
            .union(state.credentialReplacementIDs ?? []).union(lastKnownPending)
            .filter { $0.hasPrefix(ResetReminderPolicy.prefix) }
        guard ids.count <= ResetReminderPolicy.maximumPending else { return failStorage() }
        state.credentialReplacementIDs = ids
        guard persist(now: now) else { return false }
        return invalidateSource(now: now)
    }
    public func cancelAll(now: Date = .now) async {
        invalidateSource(now: now)
        await tail?.value
    }

    public func reconcile(snapshot: Snapshot?, verified: Bool, now: Date = .now, clockOffset: TimeInterval = 0, source: ResetReminderSource? = nil) async {
        let beganAt = clock()
        if let snapshot {
            let scope = ResetReminderPolicy.scope(snapshot)
            let cachedSequence = latestSnapshot.flatMap { ResetReminderPolicy.scope($0) == scope ? $0.sourceSequence : nil } ?? -1
            let persistedSequence = state.scope == scope ? state.sequence : -1
            guard snapshot.sourceSequence >= max(cachedSequence, persistedSequence) else { return }
            if let oldScope = latestSnapshot.map(ResetReminderPolicy.scope) ?? state.scope, oldScope != scope {
                authorizationGeneration = UUID()
                removeKnownImmediately(now: now)
            } else if verified {
                let present = Set(snapshot.windows.map { ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0) })
                let revoked = Set(snapshot.windows.filter {
                    $0.fetchOutcome == .authRequired || $0.fetchOutcome == .disabled || $0.availability != .available
                }.map { ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0) })
                let cancelled = state.records.filter { !present.contains($0.value.windowKey) || revoked.contains($0.value.windowKey) }
                enqueueCancellation(records: cancelled, now: now)
            }
        }
        latestSnapshot = snapshot; latestVerified = verified; latestClockOffset = clockOffset
        latestSource = source ?? state.source
        let ticket = UUID(); generation = ticket
        let predecessor = tail
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self, self.generation == ticket else { return }
            await self.apply(snapshot: snapshot, verified: verified, time: { self.advancingTime(from: now, beganAt: beganAt) }, clockOffset: clockOffset, source: source, ticket: ticket)
        }
        tail = task
        await task.value
    }

    private func clearOwned(ticket: UUID, now: Date = .now) async {
        let beganAt = clock()
        removeKnownImmediately(now: now)
        let predecessor = tail
        let task = Task { @MainActor [weak self] in
            if let self, ticket == self.generation {
                let pending = await self.client.pendingIDs()
                if ticket == self.generation {
                    let current = self.advancingTime(from: now, beganAt: beganAt)
                    self.lastKnownPending = pending
                    self.client.remove(ids: Array(pending.filter { $0.hasPrefix(ResetReminderPolicy.prefix) }))
                    if self.readable { _ = self.persist(now: current) }
                }
            }
            // Never let a rapid Disable→Enable bypass the older add. That
            // older completion must finish its ID cleanup before a new add.
            await predecessor?.value
        }
        tail = task; await task.value
    }

    private func apply(snapshot: Snapshot?, verified: Bool, time: @MainActor () -> Date, clockOffset: TimeInterval, source: ResetReminderSource?, ticket: UUID) async {
        let pending = await client.pendingIDs()
        var now = time()
        let pendingEvidenceAt = now
        guard generation == ticket else { return }
        lastKnownPending = pending
        let owned = pending.filter { $0.hasPrefix(ResetReminderPolicy.prefix) }
        if let ids = state.credentialReplacementIDs {
            client.remove(ids: Array(ids))
            let after = await client.pendingIDs()
            now = time()
            guard generation == ticket else { return }
            lastKnownPending = after
            guard ids.isDisjoint(with: after) else { status = LocalizedStatus("resetReminder.suppressed"); return }
            state.credentialReplacementIDs = nil
            guard persist(now: now) else { return }
        }
        guard await cancelRecords(state.cancelledRecords ?? [:], before: pending, evidenceAt: pendingEvidenceAt,
            time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
        now = time()
        guard readable, settings.enabled else {
            guard await cancelRecords(state.records, before: pending, evidenceAt: pendingEvidenceAt,
                time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
            client.remove(ids: Array(owned))
            now = time()
            if readable { _ = persist(now: now) }
            return
        }
        let authorized = (try? await client.authorize(requestIfNeeded: false)) ?? false
        now = time()
        guard generation == ticket else { return }
        guard authorized else {
            guard await cancelRecords(state.records, before: pending, evidenceAt: pendingEvidenceAt,
                time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
            client.remove(ids: Array(owned))
            now = time()
            guard persist(now: now) else { return }
            status = LocalizedStatus("resetReminder.denied"); return
        }
        // Prepared records recover a crash after OS acceptance but before commit.
        for id in pending where state.records[id] != nil {
            state.records[id]?.accepted = true
            if let record = state.records[id] { state.issuedCycles[record.cycleID] = record.resetsAt }
        }
        client.remove(ids: Array(owned.subtracting(state.records.keys)))
        // Account removals/pauses override preservation of an offline forecast.
        let removedAccounts = state.records.filter { _, record in state.allowedAccounts.map { !$0.contains(record.accountKey) } ?? false }
        guard await cancelRecords(removedAccounts, before: pending, evidenceAt: pendingEvidenceAt,
            time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
        now = time()
        // An offset change may cancel an old timing while offline, but may not
        // create a replacement from cached observations.
        let oldTimings = state.records.filter { $0.value.leadMinutes != settings.leadMinutes }
        if !verified {
            guard await cancelRecords(oldTimings, before: pending, evidenceAt: pendingEvidenceAt,
                time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
            now = time()
        }
        // A cryptographically accepted retained snapshot identifies its owner
        // even when its observations are offline. Cancel the previous owner
        // before deciding whether any new forecast is fresh enough to schedule.
        if let snapshot {
            let scope = ResetReminderPolicy.scope(snapshot)
            if state.scope == scope && snapshot.sourceSequence < state.sequence { return }
            if state.scope != nil && state.scope != scope {
                guard await cancelRecords(state.records, before: pending, evidenceAt: pendingEvidenceAt,
                    time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
                now = time()
                state.windowObservations.removeAll(); state.source = nil
            }
            state.scope = scope; state.sequence = snapshot.sourceSequence
            if let source { state.source = source }
        }
        if verified, let snapshot {
            let present = Set(snapshot.windows.map { ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0) })
            let revoked = Set(snapshot.windows.filter {
                $0.fetchOutcome == .authRequired || $0.fetchOutcome == .disabled || $0.availability != .available
            }.map { ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0) })
            let cancelled = state.records.filter { !present.contains($0.value.windowKey) || revoked.contains($0.value.windowKey) }
            guard await cancelRecords(cancelled, before: pending, evidenceAt: pendingEvidenceAt,
                time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
            now = time()
        }
        var rolledBackWindows = Set<String>()
        var observationCap = false
        for window in snapshot?.windows ?? [] {
            guard let snapshot else { continue }
            let key = ResetReminderPolicy.windowKey(snapshot: snapshot, window: window)
            guard let observed = window.observedAt.flatMap(QuotaRules.date), observed <= now.addingTimeInterval(120) else { continue }
            let recorded = state.windowObservations[key] ?? state.records.values.filter { $0.windowKey == key }.map(\.observedAt).max()
            if let recorded, observed < recorded { rolledBackWindows.insert(key); continue }
            if state.windowObservations[key] == nil && state.windowObservations.count >= 2048 {
                rolledBackWindows.insert(key); observationCap = true; continue
            }
            state.windowObservations[key] = observed
        }
        guard verified, let snapshot, clockIsTrusted(at: now, offset: clockOffset) else {
            guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
            status = LocalizedStatus(clockIsTrusted(at: now, offset: clockOffset) ? "resetReminder.retained" : "resetReminder.clockUncertain"); return
        }
        let candidates = ResetReminderPolicy.requests(snapshot: snapshot, settings: settings, now: now, clockOffset: clockOffset)
            .filter { request in !rolledBackWindows.contains(request.windowKey) && (state.allowedAccounts.map { $0.contains(request.accountKey) } ?? true) }
        let retainedWindows = Set(snapshot.windows.filter {
            ResetReminderPolicy.preservesForecast($0, now: now) ||
                (rolledBackWindows.contains(ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0)) &&
                 $0.fetchOutcome != .authRequired && $0.fetchOutcome != .disabled && $0.availability == .available)
        }.map { ResetReminderPolicy.windowKey(snapshot: snapshot, window: $0) })
        let unrelatedCount = pending.subtracting(owned).count
        let slots = max(0, min(ResetReminderPolicy.maximumPending, ResetReminderPolicy.maximumTotalPending - unrelatedCount))
        let retainedCandidates = state.records.filter { $0.value.resetsAt > now && retainedWindows.contains($0.value.windowKey) && $0.value.leadMinutes == settings.leadMinutes }
        let retained = Dictionary(uniqueKeysWithValues: retainedCandidates.sorted {
            $0.value.fireAt == $1.value.fireAt ? $0.key < $1.key : $0.value.fireAt < $1.value.fireAt
        }.prefix(slots).map { ($0.key, $0.value) })
        let requests = Array(candidates.prefix(max(0, slots - retained.count)))
        var capped = observationCap || retainedCandidates.count + candidates.count > slots
        var suppressed = false
        let desired = Set(requests.map(\.id)).union(retained.keys)
        let obsolete = Set(state.records.keys).subtracting(desired)
        // A pre-authorization pending query cannot prove a request is still
        // pending after its fire time. Keep that deadline with replacement
        // evidence and check it again after each suspension.
        let pendingCycles = state.records.filter { pending.contains($0.key) }.values.reduce(into: [String: Date]()) { cycles, record in
            cycles[record.cycleID] = max(cycles[record.cycleID] ?? record.fireAt, record.fireAt)
        }
        guard await cancelRecords(state.records.filter { obsolete.contains($0.key) }, before: pending, evidenceAt: pendingEvidenceAt,
            time: time, clockTrusted: abs(clockOffset) <= 120, ticket: ticket) else { return }
        now = time()
        guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
        let staleDates = Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { window -> (String, Date)? in
            guard let date = window.staleAt.flatMap(QuotaRules.date) else { return nil }
            return (ResetReminderPolicy.windowKey(snapshot: snapshot, window: window), date)
        })
        func remainsFresh(_ request: ResetReminderRequest, at date: Date) -> Bool {
            clockIsTrusted(at: date, offset: clockOffset) && request.fireAt > date && request.observedAt <= date.addingTimeInterval(120) &&
                (staleDates[request.windowKey].map { $0 > date } ?? false)
        }
        for request in requests {
            now = time()
            guard ticket == generation else { return }
            if state.records[request.id]?.accepted == true { continue }
            if let oldFire = pendingCycles[request.cycleID], oldFire <= now { suppressed = true; continue }
            if state.issuedCycles[request.cycleID] != nil { suppressed = true; continue }
            if state.records[request.id] == nil && state.records.count + (state.cancelledRecords?.count ?? 0) >= ResetReminderPolicy.maximumPending {
                capped = true; continue
            }
            if !lastKnownPending.contains(request.id) &&
                (lastKnownPending.filter { $0.hasPrefix(ResetReminderPolicy.prefix) }.count >= ResetReminderPolicy.maximumPending ||
                 lastKnownPending.count >= ResetReminderPolicy.maximumTotalPending) { capped = true; continue }
            let activeCycles = Set(state.issuedCycles.keys).union(state.records.values.map(\.cycleID))
            if !activeCycles.contains(request.cycleID) && activeCycles.count >= 2048 { capped = true; continue }
            guard remainsFresh(request, at: now) else { continue }
            state.records[request.id] = Record(cycleID: request.cycleID, accountKey: request.accountKey, windowKey: request.windowKey, leadMinutes: settings.leadMinutes, fireAt: request.fireAt, resetsAt: request.resetsAt, observedAt: request.observedAt, accepted: false)
            guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
            do {
                now = time()
                guard remainsFresh(request, at: now) else {
                    state.records.removeValue(forKey: request.id)
                    state.issuedCycles.removeValue(forKey: request.cycleID) // No add was attempted.
                    guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
                    continue
                }
                try await client.add(request)
                now = time()
                guard generation == ticket else { client.remove(ids: [request.id]); return }
                lastKnownPending.insert(request.id)
                state.records[request.id]?.accepted = true; state.issuedCycles[request.cycleID] = request.resetsAt
                guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
            } catch {
                guard generation == ticket else { client.remove(ids: [request.id]); return }
                state.records.removeValue(forKey: request.id)
                state.issuedCycles.removeValue(forKey: request.cycleID) // This add explicitly failed.
                guard persist(now: now) else { client.remove(ids: Array(owned.union(state.records.keys))); return }
                status = LocalizedStatus("resetReminder.unavailable"); return
            }
        }
        if !clockIsTrusted(at: time(), offset: clockOffset) { status = LocalizedStatus("resetReminder.clockUncertain") }
        else if capped { status = LocalizedStatus("resetReminder.capped", state.records.count) }
        else if suppressed { status = LocalizedStatus("resetReminder.suppressed") }
        else { status = LocalizedStatus("resetReminder.scheduled", state.records.count) }
    }
}
