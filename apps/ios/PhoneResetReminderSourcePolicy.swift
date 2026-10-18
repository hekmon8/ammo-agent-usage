import Foundation

/// A refresh belongs to a concrete client, credential scope and generation.
/// Checking only the generation cannot detect an old client under a new epoch.
public struct PhoneRefreshIdentity: Equatable, Sendable {
    public let generation: UUID
    public let credentialScope: String
    public let clientIdentifier: ObjectIdentifier?
    public init(generation: UUID, credentialScope: String, clientIdentifier: ObjectIdentifier?) {
        self.generation = generation; self.credentialScope = credentialScope; self.clientIdentifier = clientIdentifier
    }
    public func accepts(current: PhoneRefreshIdentity, transitioning: Bool) -> Bool { !transitioning && self == current }
}

public enum PhoneResetReminderSourcePolicy {
    @MainActor
    public static func commitCredentialReplacement(coordinator: ResetReminderCoordinator, now: Date = .now,
                                                   save: () throws -> Void) throws -> Bool {
        guard coordinator.prepareCredentialReplacement(now: now) else { return false }
        try save()
        return true
    }

    /// Loaded transport preferences are authoritative even when no replacement
    /// snapshot is available. Run this before startup awaits any other work.
    @MainActor
    @discardableResult
    public static func reconcileTransportPreferences(coordinator: ResetReminderCoordinator,
                                                      cfEnabled: Bool, iCloudEnabled: Bool,
                                                      now: Date = .now) -> Bool {
        let cancel = (!cfEnabled && !iCloudEnabled) || shouldCancel(source: coordinator.source,
            eligibilitySource: coordinator.eligibilitySource, cfRevoked: false, iCloudRevoked: false,
            cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled)
        if cancel { coordinator.invalidateSource(now: now) }
        return cancel
    }

    /// Accept an authoritative transport revocation and invalidate reminder
    /// eligibility synchronously, before the host awaits another transport.
    @MainActor
    @discardableResult
    public static func acceptRevocation(source: ResetReminderSource, coordinator: ResetReminderCoordinator,
                                        identity: PhoneRefreshIdentity, currentIdentity: PhoneRefreshIdentity,
                                        transitioning: Bool, cfEnabled: Bool, iCloudEnabled: Bool,
                                        now: Date = .now) -> Bool {
        guard identity.accepts(current: currentIdentity, transitioning: transitioning) else { return false }
        if shouldCancel(source: coordinator.source, eligibilitySource: coordinator.eligibilitySource,
                        cfRevoked: source == .cloudflare, iCloudRevoked: source == .iCloud,
                        cfEnabled: cfEnabled, iCloudEnabled: iCloudEnabled) {
            coordinator.invalidateSource(now: now)
        }
        return true
    }

    public static func shouldCancel(source: ResetReminderSource?, eligibilitySource: ResetReminderSource? = nil,
                                    cfRevoked: Bool, iCloudRevoked: Bool,
                                    cfEnabled: Bool, iCloudEnabled: Bool) -> Bool {
        let owners = [source, eligibilitySource].compactMap { $0 }
        if !owners.isEmpty {
            return owners.contains { owner in
                switch owner {
                case .cloudflare: return cfRevoked || !cfEnabled
                case .iCloud: return iCloudRevoked || !iCloudEnabled
                case .local: return false
                }
            }
        }
        // Legacy ledgers without either provenance are still unambiguous when
        // exactly one transport is enabled on restart.
        return (cfRevoked && cfEnabled && !iCloudEnabled) || (iCloudRevoked && iCloudEnabled && !cfEnabled)
    }
}

/// A released operation cannot unlock a newer credential transition.
public struct PhoneCredentialTransition: Sendable {
    private var owner: UUID?
    public init() {}
    public var isTransitioning: Bool { owner != nil }
    public mutating func begin() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; return token
    }
    public mutating func finish(_ token: UUID) { if owner == token { owner = nil } }
}
