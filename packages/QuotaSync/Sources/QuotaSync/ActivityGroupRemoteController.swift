import Foundation
import CryptoKit

public struct ActivityGroupBinding: Sendable {
    public let groupID: String
    public let windowIDs: [String]
    public let sourceDeviceID, sourceEpoch: String
    public let endsAt: Date
    public init(groupID: String, windowIDs: [String], sourceDeviceID: String, sourceEpoch: String, endsAt: Date) {
        self.groupID = groupID; self.windowIDs = windowIDs; self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch; self.endsAt = endsAt
    }
}

/// The native bridge uses this same controller; tests suspend its actual service
/// calls rather than approximating the asynchronous registrar with a model.
public protocol ActivityGroupServing: Sendable {
    func supportsGroups() async throws -> Bool
    func displayState() async throws -> ActivityDisplayState
    func stop(_ fence: ActivityGroupJournal.Fence) async throws -> ActivityGroupReceipt
    func register(_ journal: ActivityGroupJournal, token: Data, environment: APNSEnvironment) async throws -> ActivityGroupReceipt
    func end(groupID: String) async throws
}

public struct PairedActivityGroupService: ActivityGroupServing {
    private let capabilitiesClient: LiveActivityClient
    private let groupClient: LiveActivityGroupClient
    public init(credentials: ViewerCredentials) throws {
        capabilitiesClient = try .init(credentials: credentials); groupClient = try .init(credentials: credentials)
    }
    public func supportsGroups() async throws -> Bool { try await capabilitiesClient.capabilities().canRegisterGroups }
    public func displayState() async throws -> ActivityDisplayState { try await groupClient.displayState() }
    public func stop(_ fence: ActivityGroupJournal.Fence) async throws -> ActivityGroupReceipt {
        try await groupClient.stop(expectedDisplayRevision: fence.expectedRevision, commandID: fence.commandID, abandon: fence.abandon)
    }
    public func register(_ journal: ActivityGroupJournal, token: Data, environment: APNSEnvironment) async throws -> ActivityGroupReceipt {
        guard let request = journal.registration, let id = journal.groupID else { throw SyncError.configuration }
        return try await groupClient.register(groupID: id, expectedDisplayRevision: request.expectedDisplayRevision,
            expectedRegistrationRevision: request.expectedRegistrationRevision, commandID: request.commandID,
            windowIDs: journal.windowIDs, sourceDeviceID: journal.sourceDeviceID, sourceEpoch: journal.sourceEpoch,
            pushToken: token, environment: environment, endsAt: journal.endsAt, consent: true, now: request.preparedAt)
    }
    public func end(groupID: String) async throws { try await groupClient.end(groupID: groupID) }
}

@MainActor
public protocol ActivityGroupJournalStoring {
    func load(scope: String) -> ActivityGroupJournal
    func save(_ journal: ActivityGroupJournal, scope: String) throws
}
@MainActor
public final class DefaultsActivityGroupJournalStore: ActivityGroupJournalStoring {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(scope: String) -> ActivityGroupJournal {
        defaults.data(forKey: "quota.activity.groupJournal." + scope)
            .flatMap { try? JSONDecoder().decode(ActivityGroupJournal.self, from: $0) } ?? .init()
    }
    public func save(_ journal: ActivityGroupJournal, scope: String) throws {
        defaults.set(try JSONEncoder().encode(journal), forKey: "quota.activity.groupJournal." + scope)
    }
}

@MainActor
public final class ActivityGroupRemoteController {
    public enum Status: Sendable { case waitingToken, registered, waiting, restartRequired }
    public private(set) var available = false
    public private(set) var cleanupPending = false
    public private(set) var sessionStatus: [String: Status] = [:]
    public var onChange: (() -> Void)?
    /// System bridge hooks never request an Activity or update its quota values.
    public var matchesLocalDisplay: (ActivityGroupJournal) -> Bool = { _ in false }
    public var existingToken: (ActivityGroupJournal) -> Data? = { _ in nil }
    public var retireLocalDisplay: (String) async -> Void = { _ in }
    private let store: any ActivityGroupJournalStoring
    private let clock: () -> Date
    private final class Context {
        let scope: String
        let service: any ActivityGroupServing
        let environment: APNSEnvironment?
        var journal: ActivityGroupJournal
        var supportsGroups = false
        var needsCapabilityRetry = true
        var retryCapabilityAfter = Date.distantPast
        var storageFailed = false
        init(scope: String, service: any ActivityGroupServing, environment: APNSEnvironment?, journal: ActivityGroupJournal) {
            self.scope = scope; self.service = service; self.environment = environment; self.journal = journal
        }
    }
    private var context: Context?
    private var retired: [Context] = []
    private var generation = UUID()
    private var configuration = UUID()
    private var enabled = false
    private var configuring = false
    private var queue: Task<Void, Never>?
    public init(store: any ActivityGroupJournalStoring, clock: @escaping () -> Date = { .now }) { self.store = store; self.clock = clock }

    private func publish() {
        available = enabled && !configuring && context?.supportsGroups == true && context?.environment != nil && context?.journal.pendingStop == false && context?.storageFailed == false
        cleanupPending = context?.journal.pendingStop == true || retired.contains { $0.journal.pendingStop }
        onChange?()
    }
    @discardableResult private func persist(_ c: Context) -> Bool {
        do { try store.save(c.journal, scope: c.scope); c.storageFailed = false; publish(); return true }
        catch { c.storageFailed = true; generation = UUID(); publish(); return false }
    }
    private func serialized(_ action: @escaping @MainActor () async -> Void) async {
        let predecessor = queue
        let task = Task { @MainActor in await predecessor?.value; await action() }
        queue = task; await task.value
    }
    private func markStopped(_ c: Context) {
        c.journal.stopIntent(); generation = UUID(); _ = persist(c)
    }

    public func configure(scope: String, service: any ActivityGroupServing, environment: APNSEnvironment?) async {
        let expected = UUID(); configuration = expected; enabled = true; configuring = true; available = false
        if let old = context, old.scope != scope, old.supportsGroups || old.journal.groupID != nil || old.journal.pendingStop { markStopped(old) }
        publish()
        await serialized { [self] in
            guard configuration == expected, enabled else { return }
            if let old = context, old.scope != scope {
                _ = await finishFence(old, abandon: true)
                if old.journal.pendingStop && !retired.contains(where: { $0 === old }) { retired.append(old) }
            }
            guard configuration == expected, enabled else { return }
            let reclaimed = retired.first { $0.scope == scope }
            let journal = context?.scope == scope ? context!.journal : reclaimed?.journal ?? store.load(scope: scope)
            // Transfer the sole journal owner before any suspension. A retired
            // copy may never fence or persist over a later group in this scope.
            retired.removeAll { $0.scope == scope }
            // Client + environment + journal switch as one immutable ownership context,
            // even if the new service's capabilities later fail or are superseded.
            let next = Context(scope: scope, service: service, environment: environment, journal: journal)
            context = next; sessionStatus.removeAll(); publish()
            if next.journal.requiresAbandonment || (next.journal.groupID != nil && !matchesLocalDisplay(next.journal)) {
                let interrupted = next.journal.groupID
                markStopped(next)
                if let interrupted { await retireLocalDisplay(interrupted) }
                guard configuration == expected, enabled, context === next else { return }
            }
            do {
                let supported = try await service.supportsGroups()
                guard configuration == expected, enabled, context === next else { return }
                next.supportsGroups = supported
                next.needsCapabilityRetry = false
                guard supported, environment != nil else { configuring = false; publish(); return }
                if next.journal.pendingStop { _ = await finishFence(next, abandon: true) }
                guard configuration == expected, enabled, context === next else { return }
                configuring = false; publish()
            } catch { guard configuration == expected, context === next else { return }; next.supportsGroups = false; next.needsCapabilityRetry = true; configuring = false; publish() }
        }
    }

    /// Restore durable cleanup with existing paired credentials while the CF
    /// preference remains off. This path never probes capabilities or registers.
    public func restoreCleanup(scope: String, service: any ActivityGroupServing) async {
        markDisabled()
        let expected = configuration
        await serialized { [self] in
            guard configuration == expected, !enabled else { return }
            if let old = context, old.scope != scope {
                markStopped(old); _ = await finishFence(old, abandon: true)
                if old.journal.pendingStop && !retired.contains(where: { $0 === old }) { retired.append(old) }
            }
            guard configuration == expected, !enabled else { return }
            let reclaimed = retired.first { $0.scope == scope }
            let journal = context?.scope == scope ? context!.journal : reclaimed?.journal ?? store.load(scope: scope)
            retired.removeAll { $0.scope == scope }
            let next = Context(scope: scope, service: service, environment: nil, journal: journal)
            next.needsCapabilityRetry = false
            context = next; sessionStatus.removeAll()
            if next.journal.groupID != nil || next.journal.pendingStop {
                let id = next.journal.groupID
                markStopped(next)
                if let id { await retireLocalDisplay(id) }
                guard configuration == expected, !enabled, context === next else { return }
                _ = await finishFence(next, abandon: true)
            }
            publish()
        }
    }

    public func prepare(_ binding: ActivityGroupBinding) async -> Bool {
        let validID: (String) -> Bool = { $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }
        guard validID(binding.groupID), validID(binding.sourceDeviceID), validID(binding.sourceEpoch),
              (1...2).contains(binding.windowIDs.count), Set(binding.windowIDs).count == binding.windowIDs.count,
              binding.windowIDs.allSatisfy(validID), binding.endsAt > clock(), binding.endsAt <= clock().addingTimeInterval(8*3600) else { return false }
        guard let captured = context else { return false }
        var prepared = false
        let expected = generation
        await serialized { [self] in
            guard generation == expected, context === captured, available, !captured.journal.pendingStop else { return }
            do {
                let state = try await captured.service.displayState()
                guard generation == expected, context === captured, available else { return }
                guard state.stopped, state.groupId == nil else { markStopped(captured); _ = await finishFence(captured, abandon: true); return }
                captured.journal.displayRevision = state.displayRevision
                captured.journal.begin(groupID: binding.groupID, windowIDs: binding.windowIDs,
                    sourceDeviceID: binding.sourceDeviceID, sourceEpoch: binding.sourceEpoch, endsAt: binding.endsAt)
                prepared = persist(captured)
            } catch { prepared = false }
        }
        return prepared
    }
    public func localCreated(sessionID: String) {
        guard let c = context, c.journal.groupID == sessionID, !c.journal.pendingStop, enabled else { return }
        c.journal.localCreated = true
        if persist(c) { sessionStatus[sessionID] = .waitingToken; publish() }
    }
    public func replacePushToken(_ token: Data, sessionID: String) async {
        guard let captured = context else { return }
        let expected = generation
        await serialized { [self] in await performRegistration(captured, token: token, sessionID: sessionID, generation: expected) }
    }
    private func performRegistration(_ c: Context, token: Data, sessionID: String, generation expected: UUID) async {
        guard generation == expected, context === c, available, !c.journal.pendingStop, c.journal.localCreated,
              c.journal.groupID == sessionID, let environment = c.environment else { return }
        let hash = SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
        if let pending = c.journal.registration, pending.tokenHash != hash { await abandonRegistration(c, sessionID: sessionID); return }
        if c.journal.registration == nil {
            c.journal.registration = .init(displayRevision: c.journal.displayRevision,
                registrationRevision: c.journal.registrationRevision, tokenHash: hash, preparedAt: clock())
            guard persist(c) else { return }
        }
        guard let request = c.journal.registration else { return }
        do {
            let receipt = try await c.service.register(c.journal, token: token, environment: environment)
            guard generation == expected, context === c, !c.journal.pendingStop, enabled else { return }
            c.journal.displayRevision = receipt.displayRevision; c.journal.registrationRevision = receipt.registrationRevision ?? 0
            c.journal.registration = nil
            guard persist(c) else { return }
            sessionStatus[sessionID] = .registered; publish()
            // A replay can acknowledge a committed request after its old coverage
            // expired. Renew that known registration once, without creating a card.
            if min(c.journal.endsAt, request.preparedAt.addingTimeInterval(4*3600)) <= clock(), c.journal.endsAt > clock() {
                await performRegistration(c, token: token, sessionID: sessionID, generation: expected)
            }
        } catch TransportError.rejected(let code) where code == 400 || code == 409 {
            guard generation == expected, context === c, !c.journal.pendingStop else { return }
            await abandonRegistration(c, sessionID: sessionID)
        } catch {
            guard generation == expected, context === c else { return }
            if min(c.journal.endsAt, request.preparedAt.addingTimeInterval(4*3600)) <= clock() {
                await abandonRegistration(c, sessionID: sessionID)
            } else { sessionStatus[sessionID] = .waiting; publish() }
        }
    }
    private func abandonRegistration(_ c: Context, sessionID: String) async {
        markStopped(c); sessionStatus[sessionID] = .restartRequired; publish()
        await retireLocalDisplay(sessionID)
        _ = await finishFence(c, abandon: true)
    }

    public func markStopped() {
        generation = UUID()
        guard let c = context else { return }
        // A legacy service with no v2 requests has no remote cleanup obligation.
        guard c.supportsGroups || c.journal.groupID != nil || c.journal.pendingStop else { return }
        markStopped(c); sessionStatus.removeAll(); publish()
    }
    public func stop(abandon: Bool = false) async {
        markStopped(); guard let captured = context else { return }
        await serialized { [self] in _ = await finishFence(captured, abandon: abandon) }
    }
    private func finishFence(_ c: Context, abandon: Bool) async -> Bool {
        guard c.journal.pendingStop else { return true }
        for _ in 0..<3 {
            do {
                if c.journal.fence == nil {
                    let state = try await c.service.displayState()
                    c.journal.fence = .init(expectedRevision: state.displayRevision, abandon: abandon)
                    guard persist(c) else { return false }
                }
                guard let fence = c.journal.fence else { return false }
                let old = c.journal.groupID
                let receipt = try await c.service.stop(fence)
                c.journal.acknowledgeFence(displayRevision: receipt.displayRevision)
                guard persist(c) else { return false }
                if let old {
                    if fence.abandon { await retireLocalDisplay(old) }
                    try? await c.service.end(groupID: old)
                }
                return true
            } catch TransportError.rejected(409) { c.journal.fence = nil; _ = persist(c) }
            catch { _ = persist(c); return false }
        }
        return false
    }
    public func endActivity(sessionID: String) async {
        if context?.journal.groupID == sessionID { await stop(abandon: true) }
    }
    public func markDisabled() {
        configuration = UUID(); enabled = false; configuring = false; available = false
        markStopped(); publish()
    }
    public func disable() async {
        markDisabled()
        await stop(abandon: true); publish()
    }
    public func recover() async {
        // Cleanup is independent of enabled/registration availability. Ordinary
        // refresh can settle a durable Stop after connectivity returns.
        await serialized { [self] in
            for old in retired where old.journal.pendingStop { _ = await finishFence(old, abandon: true) }
            retired.removeAll { !$0.journal.pendingStop }
            guard let c = context else { publish(); return }
            if c.journal.pendingStop { _ = await finishFence(c, abandon: true) }
            if enabled, c.needsCapabilityRetry, clock() >= c.retryCapabilityAfter {
                let expected = configuration
                do {
                    let supported = try await c.service.supportsGroups()
                    guard configuration == expected, enabled, context === c else { return }
                    c.supportsGroups = supported; c.needsCapabilityRetry = false
                } catch {
                    guard configuration == expected, context === c else { return }
                    c.retryCapabilityAfter = clock().addingTimeInterval(30)
                }
            }
            publish()
            guard available, !c.journal.pendingStop, let id = c.journal.groupID else { return }
            guard matchesLocalDisplay(c.journal) else { markStopped(c); _ = await finishFence(c, abandon: true); return }
            if let token = existingToken(c.journal) { await performRegistration(c, token: token, sessionID: id, generation: generation) }
        }
    }
}
