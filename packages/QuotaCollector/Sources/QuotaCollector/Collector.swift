import Foundation
import QuotaCore
import QuotaStore
import QuotaProviders

/// Precise ordering proof belongs to one actual collected window. Probe dates
/// cannot stand in for a different retained measurement after rollback.
public struct GitHubExpenseObservation: Sendable {
    public let observedAt: Date
    private let signature: Data?
    fileprivate init(window: QuotaWindow, observedAt: Date) {
        self.observedAt = observedAt
        signature = Self.signature(window)
    }
    private static func signature(_ window: QuotaWindow) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(window.withHistory([]))
    }
    fileprivate func matches(_ window: QuotaWindow) -> Bool {
        guard let signature else { return false }
        return signature == Self.signature(window)
    }
}

public struct ProviderHealth: Sendable {
    public let providerID: String
    public var outcome: FetchOutcome
    public var nextDue: Date?
    public var failures: Int
    public var lastDuration: TimeInterval?
}
public struct CollectorProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let providerID: String?

    public init(completed: Int, total: Int, providerID: String?) {
        self.completed = completed
        self.total = total
        self.providerID = providerID
    }
}

/// Device-local polling choices; failure retry deadlines remain independent.
public enum CollectorRefreshInterval: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

/// One actor, one sleeping scheduler, and at most one provider subprocess across all accounts.
public actor Collector {
    private let store: SnapshotStore
    private let deviceID: String
    private let epoch: String
    private let providers: [String: any QuotaProvider]
    private var health: [String: ProviderHealth] = [:]
    private var windows: [QuotaWindow] = []
    private var loop: Task<Void, Never>?
    private var active: (id: UUID, task: Task<Void, Error>)?
    private var stopped = true
    private var suspended = false
    private var lastAttempt: [String: Date] = [:]
    private var retryDeadlines: [String: Date]
    private var githubExpenseObservations: [String: GitHubExpenseObservation]
    private var retainedInvalidationPending = false
    private var snapshotPublicationPending = false
    private var refreshInterval: CollectorRefreshInterval = .fiveMinutes
    private var lowPower = false
    private var interval: TimeInterval { max(refreshInterval.seconds, lowPower ? 900 : 0) }
    private let onSnapshot: (@Sendable (Snapshot) async -> Void)?
    private let onProgress: (@Sendable (CollectorProgress?) async -> Void)?
    private let onPassComplete: (@Sendable (Snapshot) async -> Void)?
    private let lease: CollectorLease
    public init(store: SnapshotStore, directory: URL, providers: [any QuotaProvider], deviceID: String, epoch: String, retryNotBefore: [String: Date] = [:], githubExpenseObservations: [String: GitHubExpenseObservation] = [:], onSnapshot: (@Sendable (Snapshot) async -> Void)? = nil, onProgress: (@Sendable (CollectorProgress?) async -> Void)? = nil, onPassComplete: (@Sendable (Snapshot) async -> Void)? = nil) throws {
        guard store.directory.standardizedFileURL == directory.standardizedFileURL else { throw StoreError.conflict }
        self.onSnapshot = onSnapshot
        self.onProgress = onProgress
        self.onPassComplete = onPassComplete
        self.store = store; self.deviceID = deviceID; self.epoch = epoch
        self.retryDeadlines = retryNotBefore
        self.githubExpenseObservations = githubExpenseObservations
        var indexed: [String: any QuotaProvider] = [:]
        var identities = Set<String>()
        for provider in providers {
            guard identities.insert(provider.definition.id + "/" + provider.credentialIdentity).inserted else { throw StoreError.conflict }
            let key = provider.definition.id + "/" + provider.accountID
            guard indexed[key] == nil else { throw StoreError.conflict }
            indexed[key] = provider
            health[key] = ProviderHealth(providerID: provider.definition.id, outcome: .ok, nextDue: Date(), failures: 0, lastDuration: nil)
            if let retry = retryNotBefore[key], retry > Date() {
                health[key]?.outcome = .throttled; health[key]?.failures = 1; health[key]?.nextDue = retry
            }
        }
        self.providers = indexed
        lease = try CollectorLease(directory: directory)
    }
    deinit { loop?.cancel(); active?.task.cancel() }
    public func start() async throws {
        guard stopped else { return }
        let configured = Set(providers.keys)
        windows = try await store.latest()?.windows.filter {
            configured.contains($0.providerId + "/" + $0.accountId)
        } ?? []
        snapshotPublicationPending = false
        try Task.checkCancellation()
        githubExpenseObservations = githubExpenseObservations.filter { key, proof in
            windows.contains { $0.providerId + "/" + $0.accountId == key && proof.matches($0) }
        }
        stopped = false
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let delay = await self.nextDelay()
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    public func stop() async {
        stopped = true
        let scheduler = loop; scheduler?.cancel(); loop = nil
        let task = active?.task; task?.cancel(); _ = try? await task?.value; active = nil
        // The scheduler holds self across its sleep. Join it before returning
        // so releasing this collector also releases its exclusive store lease.
        await scheduler?.value
    }
    public func setSuspended(_ value: Bool) {
        suspended = value
        if value { active?.task.cancel() }
        else {
            let now = Date()
            for key in health.keys where health[key]?.outcome != .authRequired && health[key]?.outcome != .disabled {
                if let state = health[key], state.failures > 0, let due = state.nextDue, due > now { continue }
                health[key]?.nextDue = now.addingTimeInterval(Double.random(in: 1...5))
            }
        }
    }
    public func setRefreshInterval(_ value: CollectorRefreshInterval) {
        let previous = interval
        refreshInterval = value
        if interval != previous { rescheduleHealthyProviders() }
    }
    public func setLowPower(_ value: Bool) {
        let previous = interval
        lowPower = value
        if interval != previous { rescheduleHealthyProviders() }
    }
    private func rescheduleHealthyProviders() {
        // Anchor to the last attempt, not the settings change. Never shorten a
        // failure's Retry-After/auth deadline or re-enable a paused provider.
        for key in health.keys where health[key]?.outcome == .ok && health[key]?.failures == 0 {
            if let attempted = lastAttempt[key] {
                health[key]?.nextDue = attempted.addingTimeInterval(interval)
            }
        }
    }
    public func setEnabled(_ enabled: Bool, key: String) {
        guard health[key] != nil else { return }
        let retry = retryDeadlines[key].flatMap { $0 > Date() ? $0 : nil }
        health[key]?.outcome = enabled ? (retry == nil ? .ok : .throttled) : .disabled
        health[key]?.failures = retry == nil ? 0 : 1
        health[key]?.nextDue = enabled ? (retry ?? Date()) : nil
        if !enabled { active?.task.cancel() }
    }
    public func retainedRetryDeadlines() -> [String: Date] {
        retryDeadlines.filter { $0.value > Date() }
    }
    public func retainedGitHubExpenseObservations() -> [String: GitHubExpenseObservation] { githubExpenseObservations }
    private func invalidateRetainedGitHubExpenses(failures: [String: Date]) {
        windows = windows.map { window in
            guard window.providerId == "github-actions", window.quotaKey == "cost-spend",
                  let failedAt = failures["github-actions/" + window.accountId], window.availability != .unavailable else { return window }
            let key = "github-actions/" + window.accountId
            let proof = githubExpenseObservations[key]
            let observedAt = (proof?.matches(window) == true ? proof?.observedAt : nil) ?? window.observedAt.flatMap(QuotaRules.date)
            if let observedAt, observedAt > failedAt { return window }
            retainedInvalidationPending = true
            let outcome: FetchOutcome = retryDeadlines["github-actions/" + window.accountId].map { $0 > Date() } == true ? .throttled : .error
            return window.withoutMeasurement(outcome: outcome, now: Date())
        }
    }
    @discardableResult
    public func publishRetainedGitHubInvalidation(failures: [String: Date]) async throws -> Bool {
        guard !stopped else { return false }
        if let previous = active {
            _ = try? await previous.task.value
            try Task.checkCancellation()
            if active?.id == previous.id { active = nil }
            return try await publishRetainedGitHubInvalidation(failures: failures)
        }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            self.invalidateRetainedGitHubExpenses(failures: failures)
            guard self.retainedInvalidationPending || self.snapshotPublicationPending, !self.windows.isEmpty else { return }
            let snapshot = try await self.publish()
            self.retainedInvalidationPending = false
            await self.onPassComplete?(snapshot)
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        try await task.value
        return true
    }
    public func diagnostics() -> [ProviderHealth] { health.sorted(by: { $0.key < $1.key }).map(\.value) }
    public func current() -> [QuotaWindow] { windows }
    public func refresh(providerID: String? = nil, scheduled: Bool = false) async throws {
        guard !stopped, !suspended else { throw StoreError.unavailable }
        if let previous = active {
            do { try await previous.task.value }
            catch is CancellationError where previous.task.isCancelled {
                // Disabling a provider cancels its pass, not a new refresh
                // waiting for it to finish after the provider is re-enabled.
            }
            try Task.checkCancellation()
            if active?.id == previous.id { active = nil }
            return try await refresh(providerID: providerID, scheduled: scheduled)
        }
        // Auth-latched keys stay eligible: their retry deadline in perform gates
        // them, so scheduled ticks pick them up once the low-frequency probe is
        // due and an explicit refresh retries them after the deadline passes.
        let keys = providers.keys.sorted().filter { key in
            (providerID == nil || providers[key]?.definition.id == providerID) && health[key]?.outcome != .disabled
                && (!scheduled || (health[key]?.nextDue.map { $0 <= Date() } ?? false))
        }
        guard !keys.isEmpty else { throw StoreError.unavailable }
        let id = UUID()
        let task = Task {
            do {
                try await self.perform(keys)
                await onProgress?(nil)
            } catch {
                await onProgress?(nil)
                throw error
            }
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        try await task.value
    }
    private func perform(_ keys: [String]) async throws {
        var completed = 0
        var finalSnapshot: Snapshot?
        for key in keys {
            try Task.checkCancellation()
            guard !stopped, !suspended, health[key]?.outcome != .disabled, let provider = providers[key] else { continue }
            let now = Date()
            if let sharedRetry = await provider.retryNotBefore(), sharedRetry > now {
                retryDeadlines[key] = max(retryDeadlines[key] ?? sharedRetry, sharedRetry)
                let failures = max(1, health[key]?.failures ?? 0)
                let due = max(health[key]?.nextDue ?? sharedRetry, sharedRetry)
                health[key]?.outcome = .throttled; health[key]?.failures = failures
                health[key]?.nextDue = due
            }
            try Task.checkCancellation()
            guard !stopped, !suspended, health[key]?.outcome != .disabled else { continue }
            if let previous = lastAttempt[key], now.timeIntervalSince(previous) < 10 { continue }
            // Explicit refresh respects provider/server retry deadlines following a failure.
            if let state = health[key], state.failures > 0, let due = state.nextDue, due > now { continue }
            await onProgress?(CollectorProgress(completed: completed, total: keys.count, providerID: provider.definition.id))
            lastAttempt[key] = now
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let fetched = try await provider.fetch(now: now)
                let retryNotBefore = await provider.retryNotBefore()
                let expenseObservedAt = await provider.githubExpenseObservedAt()
                guard !fetched.isEmpty, fetched.allSatisfy({ $0.providerId == provider.definition.id && $0.accountId == provider.accountID }) else { throw ProviderFailure.parseChanged }
                try Task.checkCancellation()
                guard !stopped, !suspended, health[key]?.outcome != .disabled else { continue }
                var hydrated: [QuotaWindow] = []
                for window in fetched {
                    var history = try await store.history(for: window, since: now.addingTimeInterval(-86400), limit: 47)
                    if let observed = window.observedAt, history.last?.observedAt != observed {
                        history.append(.observation(at: observed, remainingBps: window.remainingBps, segmentID: window.window.periodId ?? "unknown"))
                    }
                    hydrated.append(window.withHistory(history))
                }
                let isSameAccount = { (window: QuotaWindow) in
                    window.providerId == provider.definition.id && window.accountId == provider.accountID
                }
                // Reinsert hydrated windows at the account's previous position so
                // per-provider updates never reshuffle the snapshot mid-pass;
                // otherwise dashboard cards visibly jump on every refresh.
                let retained = windows.filter { !isSameAccount($0) }
                var proposed = retained
                if let previous = windows.firstIndex(where: isSameAccount) {
                    proposed.insert(contentsOf: hydrated, at: min(previous, retained.count))
                } else {
                    proposed.append(contentsOf: hydrated)
                }
                // Reject an adapter result before mutating in-memory state. Otherwise one
                // oversized account can make the strict snapshot fail for every provider.
                let quotaIdentities = proposed.map { $0.providerId + "/" + $0.accountId + "/" + $0.quotaKey }
                guard proposed.count <= SnapshotCodec.maxWindows,
                      Set(proposed.map(\.id)).count == proposed.count,
                      Set(quotaIdentities).count == proposed.count else {
                    throw ProviderFailure.outputLimit
                }
                windows = proposed
                if provider.definition.id == "github-actions", let expenseObservedAt,
                   let expense = hydrated.first(where: { $0.quotaKey == "cost-spend" }) {
                    githubExpenseObservations[key] = GitHubExpenseObservation(window: expense, observedAt: expenseObservedAt)
                }
                health[key]?.outcome = .ok; health[key]?.failures = 0; health[key]?.nextDue = now.addingTimeInterval(interval)
                if let retry = retryNotBefore, retry > now {
                    retryDeadlines[key] = max(retryDeadlines[key] ?? retry, retry)
                    health[key]?.outcome = .throttled; health[key]?.failures = 1
                    health[key]?.nextDue = max(now.addingTimeInterval(interval), retryDeadlines[key] ?? retry)
                } else { retryDeadlines[key] = nil }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let failure = error as? ProviderFailure
                let outcome: FetchOutcome = failure == .authRequired ? .authRequired : { if case .rateLimited = failure { return .throttled }; return .error }()
                windows = windows.map {
                    guard $0.providerId == provider.definition.id && $0.accountId == provider.accountID else { return $0 }
                    if $0.providerId == "github-actions", $0.quotaKey == "cost-spend" {
                        return $0.withoutMeasurement(outcome: outcome, now: Date())
                    }
                    return $0.withOutcome(outcome)
                }
                let count = (health[key]?.failures ?? 0) + 1
                health[key]?.outcome = outcome; health[key]?.failures = count
                var delay = min(1800, 30 * pow(2, Double(min(count - 1, 6))))
                if case .rateLimited(let seconds) = failure {
                    delay = max(delay, Double(seconds))
                    let retry = Date().addingTimeInterval(Double(max(1, seconds)))
                    retryDeadlines[key] = max(retryDeadlines[key] ?? retry, retry)
                }
                if failure == .parseChanged || failure == .unsupported { delay = max(delay, 1800) }
                // An expired login retries on a low fixed cadence instead of parking
                // the account until a manual reconnect: the probe is read-only, so
                // once the CLI regains its own login the connection recovers by
                // itself. Reconnection stays the immediate path that refreshes the
                // pinned identity.
                if failure == .authRequired { delay = max(delay, 1800) }
                health[key]?.nextDue = max(now.addingTimeInterval(delay + Double.random(in: 0...5)),
                                           retryDeadlines[key] ?? .distantPast)
            }
            health[key]?.lastDuration = ProcessInfo.processInfo.systemUptime - started
            completed += 1
            finalSnapshot = try await publish()
            await onProgress?(CollectorProgress(completed: completed, total: keys.count, providerID: nil))
        }
        try Task.checkCancellation()
        if let finalSnapshot { await onPassComplete?(finalSnapshot) }
    }
    private func publish() async throws -> Snapshot {
        // A newer in-memory observation does not prove durable publication.
        // Queued invalidation must retry a failed write before reporting success.
        snapshotPublicationPending = true
        let sequence = (try await store.latest()?.sourceSequence ?? 0) + 1
        // Reduce only embedded trend detail until the strict whole-snapshot budget fits.
        var budgeted = windows
        var snapshot: Snapshot
        while true {
            do { snapshot = try Snapshot.make(windows: budgeted, deviceID: deviceID, epoch: epoch, sequence: sequence, capturedAt: Date()); break }
            catch {
                guard budgeted.contains(where: { !$0.history.isEmpty }) else { throw error }
                budgeted = budgeted.map { $0.withHistory(Array($0.history.suffix($0.history.count / 2))) }
            }
        }
        try await store.publish(SnapshotCodec.encode(snapshot))
        snapshotPublicationPending = false
        await onSnapshot?(snapshot)
        return snapshot
    }
    private func tick() async {
        guard !stopped, !suspended else { return }
        let now = Date()
        if health.values.contains(where: { $0.nextDue.map { $0 <= now } ?? false }) { try? await refresh(scheduled: true) }
    }
    private func nextDelay() -> TimeInterval {
        guard !suspended else { return 30 }
        return max(1, min(30, health.values.compactMap(\.nextDue).map { $0.timeIntervalSinceNow }.min() ?? 30))
    }
}
