import Foundation
import QuotaCore

/// The v2 wire contains independent quota rows, never account identities or totals.
public struct ActivityGroupRow: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey { case windowID, remainingBps, displayState, observedAt, staleAt, resetsAt, sequence }
    public let windowID: String
    public let remainingBps: Int?
    public let displayState: String
    public let observedAt, staleAt, resetsAt: Int64?
    public let sequence: Int64

    public init(windowID: String, remainingBps: Int?, displayState: String,
                observedAt: Int64?, staleAt: Int64?, resetsAt: Int64?, sequence: Int64) {
        self.windowID = windowID; self.remainingBps = remainingBps; self.displayState = displayState
        self.observedAt = observedAt; self.staleAt = staleAt; self.resetsAt = resetsAt; self.sequence = sequence
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowID, forKey: .windowID); try c.encode(remainingBps, forKey: .remainingBps)
        try c.encode(displayState, forKey: .displayState); try c.encode(observedAt, forKey: .observedAt)
        try c.encode(staleAt, forKey: .staleAt); try c.encode(resetsAt, forKey: .resetsAt)
        try c.encode(sequence, forKey: .sequence)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard [CodingKeys.remainingBps, .observedAt, .staleAt, .resetsAt].allSatisfy(c.contains) else { throw ActivityGroupError.invalidContent }
        self.init(windowID: try c.decode(String.self, forKey: .windowID), remainingBps: try c.decodeIfPresent(Int.self, forKey: .remainingBps),
            displayState: try c.decode(String.self, forKey: .displayState), observedAt: try c.decodeIfPresent(Int64.self, forKey: .observedAt),
            staleAt: try c.decodeIfPresent(Int64.self, forKey: .staleAt), resetsAt: try c.decodeIfPresent(Int64.self, forKey: .resetsAt),
            sequence: try c.decode(Int64.self, forKey: .sequence))
    }
}

public struct ActivityGroupContent: Codable, Hashable, Sendable {
    public let version: Int
    public let bundleRevision: Int64
    public let rows: [ActivityGroupRow]

    public init(bundleRevision: Int64 = 0, rows: [ActivityGroupRow]) throws {
        guard Self.validNumber(bundleRevision), (1...2).contains(rows.count),
              Set(rows.map(\.windowID)).count == rows.count,
              rows.allSatisfy({ Self.validID($0.windowID) && Self.validNumber($0.sequence) &&
                  [$0.observedAt, $0.staleAt, $0.resetsAt].allSatisfy { $0.map(Self.validNumber) ?? true } &&
                  ($0.remainingBps == nil || (0...10_000).contains($0.remainingBps!)) &&
                  Self.states.contains($0.displayState) }) else { throw ActivityGroupError.invalidContent }
        version = 2; self.bundleRevision = bundleRevision; self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 2 else { throw ActivityGroupError.invalidContent }
        try self.init(bundleRevision: c.decode(Int64.self, forKey: .bundleRevision), rows: c.decode([ActivityGroupRow].self, forKey: .rows))
    }

    public func staleDate(endsAt: Int64, now: Date = .now) -> Date {
        guard rows.allSatisfy({ $0.observedAt != nil && $0.staleAt != nil && $0.displayState != "unavailable" }) else { return now }
        return Date(timeIntervalSince1970: Double(min(endsAt, rows.compactMap(\.staleAt).min() ?? endsAt)))
    }

    public static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
    private static let states: Set<String> = ["fresh", "low", "exhausted", "stale", "resetPending", "unavailable", "unlimited", "authRequired", "offline", "locked", "clockSkew", "ended"]
    private static func validNumber(_ value: Int64) -> Bool { (0...9_007_199_254_740_991).contains(value) }
}

public enum ActivityGroupError: Error { case invalidContent, invalidAttributes, payloadTooLarge }

/// Only these bounded local display labels are static ActivityKit metadata.
/// Account IDs and aliases are deliberately absent from both metadata and pushes.
public struct ActivityGroupDescriptor: Codable, Hashable, Sendable {
    public let windowID, providerID, title: String
    public let accountOrdinal: Int?
    public init(windowID: String, providerID: String, title: String, accountOrdinal: Int? = nil) {
        self.windowID = windowID; self.providerID = Self.bounded(providerID)
        self.title = Self.bounded(title); self.accountOrdinal = accountOrdinal
    }
    private static func bounded(_ value: String) -> String {
        var result = ""
        for character in value.prefix(48) {
            guard result.utf8.count + String(character).utf8.count <= 144 else { break }
            result.append(character)
        }
        return result
    }
}

public struct ActivityGroupProjection: Sendable {
    public let descriptors: [ActivityGroupDescriptor]
    public let content: ActivityGroupContent
    public let supportsRemote: Bool

    public init(snapshot: Snapshot, windowIDs: [String], previous: [ActivityGroupDescriptor] = [],
                offline: Bool = false, now: Date = .now) throws {
        guard (1...2).contains(windowIDs.count), Set(windowIDs).count == windowIDs.count else { throw ActivityGroupError.invalidContent }
        let selected = windowIDs.map { id in snapshot.windows.first { $0.id == id } }
        // Ordinals distinguish exact accounts within a provider, not aliases.
        var accounts: [String: [String]] = [:]
        for w in selected.compactMap({ $0 }) {
            let key = ProviderCatalog.identity(for: w.providerId).displayName
            if !accounts[key, default: []].contains(w.accountId) { accounts[key, default: []].append(w.accountId) }
        }
        descriptors = zip(windowIDs, selected).map { id, w in
            guard let w else { return previous.first { $0.windowID == id } ?? .init(windowID: id, providerID: "ammo", title: L("widget.window.default")) }
            let accountIDs = accounts[ProviderCatalog.identity(for: w.providerId).displayName] ?? []
            let ordinal = accountIDs.count > 1 ? accountIDs.firstIndex(of: w.accountId).map { $0 + 1 } : nil
            return .init(windowID: id, providerID: w.providerId,
                         title: String(w.shortDisplayName.prefix(w.quality == .reported ? 48 : 32)) + (w.quality == .reported ? "" : L("phone.activity.labelEstimate")), accountOrdinal: ordinal)
        }
        func epoch(_ value: String?) -> Int64? { value.flatMap(QuotaRules.date).map { Int64($0.timeIntervalSince1970) } }
        let rows = zip(windowIDs, selected).map { id, w -> ActivityGroupRow in
            guard let w else { return .init(windowID: id, remainingBps: nil, displayState: "unavailable", observedAt: nil, staleAt: nil, resetsAt: nil, sequence: snapshot.sourceSequence) }
            let state = QuotaRules.state(w, now: now)
            let display = offline && ![.locked, .authRequired, .unavailable].contains(state) ? "offline" : state.rawValue
            return .init(windowID: id, remainingBps: w.remainingBps, displayState: display,
                         observedAt: epoch(w.observedAt), staleAt: epoch(w.staleAt), resetsAt: epoch(w.window.resetsAt), sequence: snapshot.sourceSequence)
        }
        content = try .init(rows: rows)
        supportsRemote = !offline && selected.allSatisfy { $0?.quality == .reported && $0?.unit == .percent }
    }
}
