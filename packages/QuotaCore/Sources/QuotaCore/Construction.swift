import Foundation

extension Snapshot {
    public static func make(windows: [QuotaWindow], deviceID: String, epoch: String, sequence: Int64, capturedAt: Date) throws -> Snapshot {
        let snapshot = Snapshot(schemaVersion: "1.0.0", snapshotId: UUID().uuidString, sourceDeviceId: deviceID, sourceEpoch: epoch, sourceSequence: sequence, capturedAt: ISO8601DateFormatter().string(from: capturedAt), windows: windows)
        _ = try SnapshotCodec.encode(snapshot)
        return snapshot
    }
}
extension QuotaWindow {
    public static func reported(id: String, providerID: String, accountID: String, alias: String, key: String,
                                remainingBps: Int?, observedAt: Date, staleAt: Date, duration: Int?, resetsAt: Date?,
                                source: SourceMethod, availability: Availability = .available) -> QuotaWindow {
        let formatter = ISO8601DateFormatter()
        return QuotaWindow(id: id, providerId: providerID, accountId: accountID, accountAlias: alias, quotaKey: key,
                           sharedPoolId: nil, unit: .percent, currency: nil, availability: availability,
                           remainingBps: remainingBps, amount: nil, limit: nil, quality: .reported, sourceMethod: source,
                           fetchOutcome: .ok, observedAt: formatter.string(from: observedAt), staleAt: formatter.string(from: staleAt),
                           window: WindowDefinition(kind: .rolling, durationSeconds: duration, startsAt: nil,
                                                    resetsAt: resetsAt.map(formatter.string), periodId: nil), history: [])
    }
    /// An observed failed expense read must not carry the previous amount as current.
    public func withoutMeasurement(outcome: FetchOutcome, now: Date) -> QuotaWindow {
        let stamp = ISO8601DateFormatter().string(from: now)
        return QuotaWindow(id: id, providerId: providerId, accountId: accountId, accountAlias: accountAlias, quotaKey: quotaKey,
            sharedPoolId: sharedPoolId, unit: unit, currency: currency, availability: .unavailable,
            remainingBps: nil, amount: nil, limit: nil, quality: .unknown, sourceMethod: sourceMethod,
            fetchOutcome: outcome, observedAt: stamp, staleAt: stamp,
            window: WindowDefinition(kind: window.kind, durationSeconds: window.durationSeconds,
                                     startsAt: window.startsAt, resetsAt: nil, periodId: window.periodId), history: [])
    }
    public func withOutcome(_ outcome: FetchOutcome) -> QuotaWindow {
        QuotaWindow(id: id, providerId: providerId, accountId: accountId, accountAlias: accountAlias, quotaKey: quotaKey,
                    sharedPoolId: sharedPoolId, unit: unit, currency: currency, availability: availability,
                    remainingBps: remainingBps, amount: amount, limit: limit, quality: quality, sourceMethod: sourceMethod,
                    fetchOutcome: outcome, observedAt: observedAt, staleAt: staleAt, window: window, history: history)
    }
}

public extension HistoryPoint {
    static func observation(at: String, remainingBps: Int?, segmentID: String) -> HistoryPoint {
        HistoryPoint(observedAt: at, remainingBps: remainingBps, segmentId: segmentID)
    }
}
public extension QuotaWindow {
    func withHistory(_ points: [HistoryPoint]) -> QuotaWindow {
        QuotaWindow(id: id, providerId: providerId, accountId: accountId, accountAlias: accountAlias, quotaKey: quotaKey,
                    sharedPoolId: sharedPoolId, unit: unit, currency: currency, availability: availability,
                    remainingBps: remainingBps, amount: amount, limit: limit, quality: quality, sourceMethod: sourceMethod,
                    fetchOutcome: fetchOutcome, observedAt: observedAt, staleAt: staleAt, window: window, history: points)
    }
}
