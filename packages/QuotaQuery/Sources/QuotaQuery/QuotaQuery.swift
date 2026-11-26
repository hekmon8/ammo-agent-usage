import Foundation
import QuotaCore
import QuotaStore

/// The only read path used by the command line and MCP surfaces.  It reads the
/// collector's atomically-published, credential-free projection and never
/// invokes a provider or starts a collector.
public struct QuotaQuery: Sendable {
    public static let schemaVersion = "1.0.0"
    public static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/QuotaIsland", isDirectory: true)

    public let directory: URL
    public var now: @Sendable () -> Date

    public init(directory: URL = QuotaQuery.defaultDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public func status(requireFresh: Bool = false) throws -> StatusProjection {
        let snapshot = try load()
        let windows = snapshot.windows.map(project)
        if requireFresh, windows.isEmpty || windows.contains(where: { !$0.isFresh }) { throw QueryError.noFreshData }
        return StatusProjection(schemaVersion: Self.schemaVersion, scope: "latest_snapshot", capturedAt: snapshot.capturedAt, windows: windows)
    }

    public func list(providerId: String? = nil, accountId: String? = nil, includeStale: Bool = true, requireFresh: Bool = false) throws -> ListProjection {
        let snapshot = try load()
        let windows = snapshot.windows.map(project).filter { window in
            (providerId == nil || window.providerId == providerId) && (accountId == nil || window.accountId == accountId)
                && (includeStale || window.isFresh)
        }
        if requireFresh, windows.isEmpty || windows.contains(where: { !$0.isFresh }) { throw QueryError.noFreshData }
        return ListProjection(schemaVersion: Self.schemaVersion, scope: "latest_snapshot", capturedAt: snapshot.capturedAt, windows: windows)
    }

    public func get(windowId: String, requireFresh: Bool = false) throws -> WindowProjection {
        let result = project(try window(try load(), windowId: windowId))
        if requireFresh, !result.isFresh { throw QueryError.noFreshData }
        return result
    }

    public func history(windowId: String, range: TimeInterval, requireFresh: Bool = false) throws -> HistoryProjection {
        guard range > 0, range <= 7 * 86_400 else { throw QueryError.invalidRange }
        let window = try window(try load(), windowId: windowId)
        let projection = project(window)
        if requireFresh, !projection.isFresh { throw QueryError.noFreshData }
        let cutoff = now().addingTimeInterval(-range)
        let points = window.history.compactMap { point -> HistoryProjection.Point? in
            guard let observedAt = QuotaRules.date(point.observedAt), observedAt >= cutoff else { return nil }
            return .init(observedAt: point.observedAt, remainingBps: point.remainingBps, segmentId: point.segmentId,
                         gap: point.remainingBps == nil)
        }
        return HistoryProjection(schemaVersion: Self.schemaVersion, scope: "bounded_snapshot_history", window: projection,
                                 rangeSeconds: Int(range), points: points,
                                 limited: true, limitation: "Points are the bounded history embedded in the latest snapshot; missing intervals are not inferred.")
    }

    public func health() throws -> HealthProjection {
        let snapshot = try load()
        let windows = snapshot.windows.map(project)
        return HealthProjection(schemaVersion: Self.schemaVersion, scope: "latest_snapshot", capturedAt: snapshot.capturedAt,
                                windowCount: windows.count, freshWindowCount: windows.filter(\.isFresh).count,
                                staleWindowCount: windows.filter { !$0.isFresh }.count)
    }

    public func providers() throws -> ProvidersProjection {
        let snapshot = try load()
        var order: [String] = []
        var accounts: [String: AccountProjection] = [:]
        for window in snapshot.windows {
            let key = window.providerId + "/" + window.accountId
            if accounts[key] == nil { order.append(key) }
            accounts[key] = AccountProjection(providerId: window.providerId, accountId: window.accountId, accountAlias: window.accountAlias,
                                              windowCount: (accounts[key]?.windowCount ?? 0) + 1)
        }
        return ProvidersProjection(schemaVersion: Self.schemaVersion, scope: "latest_snapshot",
                                   providerIds: Array(Set(snapshot.windows.map(\.providerId))).sorted(),
                                   accounts: order.map { accounts[$0]! })
    }

    private func load() throws -> Snapshot {
        do {
            guard let snapshot = try AtomicSnapshotReader(directory: directory).latest() else { throw QueryError.unavailable }
            return snapshot
        } catch let error as QueryError { throw error }
        catch { throw QueryError.unavailable }
    }

    /// Exact id, else the pre-account `provider-quotaKey` form while it names one window.
    private func window(_ snapshot: Snapshot, windowId: String) throws -> QuotaWindow {
        let resolved = snapshot.resolve(windowID: windowId)
        guard let window = resolved.window else { throw resolved.ambiguous ? QueryError.ambiguousWindow : QueryError.windowNotFound }
        return window
    }

    private func project(_ window: QuotaWindow) -> WindowProjection {
        let state = QuotaRules.state(window, now: now())
        let freshness: DisplayState
        switch state {
        case .fresh, .low, .exhausted, .unlimited:
            // A failed fetch can retain the last measurement and its original TTL.
            freshness = window.fetchOutcome == .ok && window.observedAt != nil ? state : .stale
        default:
            freshness = state
        }
        return WindowProjection(schemaVersion: Self.schemaVersion, scope: "latest_snapshot", id: window.id,
                                providerId: window.providerId, accountId: window.accountId, accountAlias: window.accountAlias,
                                quotaKey: window.quotaKey, unit: window.unit.rawValue,
                                currency: window.currency, value: .init(remainingBps: window.remainingBps, amount: window.amount, limit: window.limit),
                                availability: window.availability.rawValue, quality: window.quality.rawValue,
                                sourceMethod: window.sourceMethod.rawValue, fetchOutcome: window.fetchOutcome.rawValue,
                                observedAt: window.observedAt, staleAt: window.staleAt, freshness: freshness.rawValue,
                                resetsAt: window.window.resetsAt)
    }
}

public enum QueryError: Error, Equatable, CustomStringConvertible {
    case unavailable, noFreshData, windowNotFound, ambiguousWindow, invalidRange, invalidArgument
    public var description: String {
        switch self {
        case .unavailable: return "Ammo is not initialized or its collector snapshot is unavailable."
        case .noFreshData: return "No data satisfies the requested freshness requirement."
        case .windowNotFound: return "The requested quota window was not found."
        case .ambiguousWindow: return "The window id matches several accounts of one provider; use the account-scoped id returned by quota list."
        case .invalidRange: return "History range must be greater than zero and at most seven days."
        case .invalidArgument: return "Unknown or invalid query argument."
        }
    }
}

/// Shared allow-list primitive for the local command and MCP adapters.  Input
/// names are deliberately validated before values are interpreted.
public enum QueryArguments {
    public static func rejectUnknown(_ names: some Sequence<String>, allowed: Set<String>) throws {
        if names.contains(where: { !allowed.contains($0) }) { throw QueryError.invalidArgument }
    }
}

public struct QuotaValue: Codable, Sendable { public let remainingBps: Int?; public let amount: String?; public let limit: String? }
public struct WindowProjection: Codable, Sendable {
    public let schemaVersion, scope, id, providerId, accountId, accountAlias, quotaKey, unit: String
    public let currency: String?; public let value: QuotaValue
    public let availability, quality, sourceMethod, fetchOutcome: String
    public let observedAt, staleAt, freshness, resetsAt: String?
    public var isFresh: Bool { freshness == DisplayState.fresh.rawValue || freshness == DisplayState.low.rawValue || freshness == DisplayState.exhausted.rawValue || freshness == DisplayState.unlimited.rawValue }
}
public struct StatusProjection: Codable, Sendable { public let schemaVersion, scope, capturedAt: String; public let windows: [WindowProjection] }
public struct ListProjection: Codable, Sendable { public let schemaVersion, scope, capturedAt: String; public let windows: [WindowProjection] }
public struct HealthProjection: Codable, Sendable { public let schemaVersion, scope, capturedAt: String; public let windowCount, freshWindowCount, staleWindowCount: Int }
public struct ProvidersProjection: Codable, Sendable {
    public let schemaVersion, scope: String
    public let providerIds: [String]
    public let accounts: [AccountProjection]
}
public struct AccountProjection: Codable, Sendable { public let providerId, accountId, accountAlias: String; public let windowCount: Int }
public struct HistoryProjection: Codable, Sendable {
    public struct Point: Codable, Sendable { public let observedAt: String; public let remainingBps: Int?; public let segmentId: String; public let gap: Bool }
    public let schemaVersion, scope: String; public let window: WindowProjection; public let rangeSeconds: Int
    public let points: [Point]; public let limited: Bool; public let limitation: String
}

public enum QuotaQuerySchemas {
    public static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw QueryError.unavailable
        }
        return try Data(contentsOf: url)
    }
}
