import Foundation

/// Durable display intent is separate from selected quota rows. Loading this
/// state never means Activity.request is permitted.
public struct SingleActivityDisplayIntent: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case stopped, creating, active, needsRestart }
    public private(set) var phase: Phase
    public private(set) var generation: UUID
    public private(set) var sessionID: String?

    public init(phase: Phase = .stopped, generation: UUID = UUID(), sessionID: String? = nil) {
        self.phase = phase; self.generation = generation; self.sessionID = sessionID
    }
    public var wantsDisplay: Bool { phase == .creating || phase == .active }
    public mutating func begin(sessionID: String) -> UUID {
        generation = UUID(); phase = .creating; self.sessionID = sessionID; return generation
    }
    public mutating func created(generation expected: UUID) -> Bool {
        guard generation == expected, phase == .creating else { return false }
        phase = .active; return true
    }
    public mutating func stop() { generation = UUID(); phase = .stopped; sessionID = nil }
    public mutating func needsRestart() { generation = UUID(); phase = .needsRestart; sessionID = nil }
    public func permitsCreation(generation expected: UUID, foreground: Bool, sourceUnchanged: Bool, hasSelection: Bool) -> Bool {
        phase == .creating && generation == expected && foreground && sourceUnchanged && hasSelection
    }
    public mutating func reconcile(runningSessionIDs: Set<String>) {
        guard wantsDisplay else { return }
        guard phase == .active, let sessionID, runningSessionIDs.contains(sessionID) else { needsRestart(); return }
    }
}

public enum SingleActivityDisplayIntentStore {
    public static let key = "quota.activity.singleDisplayIntent.v2"
    public static func load(defaults: UserDefaults = .standard) -> SingleActivityDisplayIntent? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SingleActivityDisplayIntent.self, from: $0) }
    }
    public static func save(_ intent: SingleActivityDisplayIntent, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(intent) { defaults.set(data, forKey: key) }
    }
}

/// A recorded v2 user intent supersedes every legacy card. Absence of a record
/// alone preserves selected legacy cards during first-upgrade adoption.
public enum SingleActivityRecoveryPolicy {
    public static func shouldEndLegacyActivity(savedIntent: SingleActivityDisplayIntent?, selected: Bool) -> Bool {
        !selected || savedIntent != nil
    }
}

public struct LegacyActivityMaintenanceRecord: Sendable {
    public let sessionID, windowID: String
    public let remoteUpdates: Bool
    public init(sessionID: String, windowID: String, remoteUpdates: Bool) {
        self.sessionID = sessionID; self.windowID = windowID; self.remoteUpdates = remoteUpdates
    }
}

extension SingleActivityRecoveryPolicy {
    /// Existing legacy cards remain maintained until the first recorded v2
    /// action. Every suspension rechecks intent/source; this never creates cards.
    @MainActor
    public static func maintainLegacy(records: [LegacyActivityMaintenanceRecord], eligibleWindowIDs: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool, hasRecordedIntent: @escaping @MainActor () -> Bool,
        canRenewRemote: @escaping @MainActor () -> Bool,
        updateLocal: @escaping @MainActor (String, String) async -> Void,
        renewRemote: @escaping @MainActor (String, String) async -> Void,
        retire: @escaping @MainActor (String) async -> Void) async {
        for record in records {
            guard isCurrent(), !hasRecordedIntent() else { return }
            guard eligibleWindowIDs.contains(record.windowID) else { await retire(record.sessionID); continue }
            if record.remoteUpdates {
                if canRenewRemote() { await renewRemote(record.sessionID, record.windowID) }
            } else { await updateLocal(record.sessionID, record.windowID) }
        }
    }
}

/// The native registrar uses this exact queue boundary. Source/Stop eligibility
/// must remain valid after predecessor requests finish, before HTTP submission.
@MainActor
public enum LegacyActivityRegistrationPolicy {
    public static func submit(after predecessors: [Task<Bool, Never>],
        isCurrent: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor () async -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        for predecessor in predecessors { _ = await predecessor.value }
        guard isCurrent() else { return false }
        return await request()
    }
}

/// Fresh preparations use the latest accepted Host identity; queued requests
/// retain an immutable predicate. Refresh never changes the configured scope.
@MainActor
public final class LegacyActivitySourceBinding {
    private var scope: String?
    private var predicate: @MainActor (String) -> Bool = { _ in false }
    public init() {}
    public func configure(scope: String, isCurrent: @escaping @MainActor (String) -> Bool) {
        self.scope = scope; predicate = isCurrent
    }
    @discardableResult
    public func refresh(scope: String, isCurrent: @escaping @MainActor (String) -> Bool) -> Bool {
        guard self.scope == scope else { return false }
        predicate = isCurrent; return true
    }
    public func capture(windowID: String) -> (@MainActor () -> Bool)? {
        let captured = predicate
        guard captured(windowID) else { return nil }
        return { captured(windowID) }
    }
}
