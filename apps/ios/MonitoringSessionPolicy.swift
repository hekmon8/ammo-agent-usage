import Foundation
import QuotaCore

/// User intent survives an ActivityKit expiry and relaunch. Only explicit user
/// actions change it; refreshes and system lifecycle events never create activities.
public struct MonitoringSelection: Sendable, Equatable {
    public private(set) var windowIDs: [String]

    public init(windowIDs: [String] = []) {
        var seen = Set<String>()
        self.windowIDs = Array(windowIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(MonitoringSessionPolicy.maximumConcurrentSessions))
    }

    /// Absence means a legacy install may adopt existing cards. A saved empty
    /// selection is authoritative even if ActivityKit is still removing a card.
    public static func restored(savedWindowIDs: [String]?, runningWindowIDs: some Collection<String>) -> Self {
        MonitoringSelection(windowIDs: savedWindowIDs ?? Array(runningWindowIDs))
    }

    @discardableResult
    public mutating func start(windowID: String) -> Bool {
        if windowIDs.contains(windowID) { return true }
        guard MonitoringSessionPolicy.canStart(windowID: windowID, activeWindowIDs: windowIDs) else { return false }
        windowIDs.append(windowID)
        return true
    }

    public mutating func stop(windowID: String) { windowIDs.removeAll { $0 == windowID } }

    public func shouldEndExistingActivity(windowID: String) -> Bool { !windowIDs.contains(windowID) }

    public func showsDisplayControls(availableWindowCount: Int, runningActivityCount: Int) -> Bool {
        availableWindowCount > 0 || runningActivityCount > 0 || !windowIDs.isEmpty
    }

    public func canRestart(windowID: String, availableWindowIDs: some Collection<String>, sourceUnchanged: Bool, ready: Bool) -> Bool {
        ready && sourceUnchanged && windowIDs.contains(windowID) && availableWindowIDs.contains(windowID)
    }

    public func rowState(windowID: String, runningWindowIDs: some Collection<String>, offline: Bool, stale: Bool) -> MonitoringRowState {
        guard windowIDs.contains(windowID) else { return .off }
        guard runningWindowIDs.contains(windowID) else { return .systemEnded }
        if offline { return .offline }
        return stale ? .stale : .live
    }
}

public enum MonitoringRowState: Sendable, Equatable {
    case off, live, offline, stale, systemEnded

    public var primaryActionTitle: String {
        switch self {
        case .off: L("phone.monitor.start")
        case .systemEnded: L("phone.monitor.restart")
        case .live, .offline, .stale: L("phone.monitor.end")
        }
    }
}

public struct MonitoringSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let windowID: String
    public let startedAt: Date
    public let endsAt: Date

    public init(id: UUID, windowID: String, startedAt: Date) {
        self.id = id
        self.windowID = windowID
        self.startedAt = startedAt
        self.endsAt = startedAt.addingTimeInterval(MonitoringSessionPolicy.systemActivityLifetime)
    }
}

public enum MonitoringSessionStatus: Sendable, Equatable {
    case idle
    case starting(MonitoringSession)
    case active(MonitoringSession)
    case stale(MonitoringSession)
    case ended(MonitoringSession, MonitoringEndReason)
    case dismissed(MonitoringSession)

    public var session: MonitoringSession? {
        switch self {
        case .idle: nil
        case let .starting(session), let .active(session), let .stale(session), let .ended(session, _), let .dismissed(session): session
        }
    }
}

public enum MonitoringEndReason: String, Sendable, Equatable {
    case userEnded
    case systemEnded
    case deviceRevoked
    case disconnected
}

/// The Live Activity's system deadline is separate from indefinite monitoring
/// selection. An ended activity is never revived by a refresh or automatically
/// replaced; starting another activity always requires a foreground user action.
public enum MonitoringSessionPolicy {
    public static let maximumConcurrentSessions = 2
    public static let systemActivityLifetime: TimeInterval = 8 * 60 * 60

    public static func canStart(windowID: String, activeWindowIDs: some Collection<String>) -> Bool {
        !windowID.isEmpty
            && activeWindowIDs.count < maximumConcurrentSessions
            && !activeWindowIDs.contains(windowID)
    }

    public static func start(
        windowID: String,
        now: Date,
        id: UUID = UUID()
    ) -> MonitoringSessionStatus? {
        guard canStart(windowID: windowID, activeWindowIDs: [String]()) else { return nil }
        return .starting(MonitoringSession(id: id, windowID: windowID, startedAt: now))
    }

    public static func started(_ session: MonitoringSession, now: Date) -> MonitoringSessionStatus {
        now >= session.endsAt ? .ended(session, .systemEnded) : .active(session)
    }

    public static func refresh(
        _ status: MonitoringSessionStatus,
        observedAt: Date?,
        staleAt: Date?,
        now: Date
    ) -> MonitoringSessionStatus {
        switch status {
        case .ended, .dismissed: return status
        case .idle, .starting, .active, .stale: break
        }
        guard let session = status.session else { return status }
        guard now < session.endsAt else { return .ended(session, .systemEnded) }
        guard observedAt != nil, staleAt.map({ $0 > now }) ?? false else { return .stale(session) }
        return .active(session)
    }

    public static func end(_ status: MonitoringSessionStatus, reason: MonitoringEndReason) -> MonitoringSessionStatus {
        guard let session = status.session else { return status }
        return .ended(session, reason)
    }

    public static func dismiss(_ status: MonitoringSessionStatus) -> MonitoringSessionStatus {
        guard let session = status.session else { return status }
        return .dismissed(session)
    }

    public static func canUserStart(from status: MonitoringSessionStatus) -> Bool {
        switch status { case .idle, .ended, .dismissed: true; case .starting, .active, .stale: false }
    }
}
