/// Shared production orchestration around legacy awaits. The caller captures
/// its source/preference identity; obsolete continuations cannot configure v2.
@MainActor
public enum PhoneActivityTransportPolicy {
    public static func preferenceChanged(enabled: Bool, invalidateGroup: @MainActor () -> Void, invalidateLegacy: @MainActor () -> Void) {
        if !enabled { invalidateGroup(); invalidateLegacy() }
    }
    public static func configure(isCurrent: @escaping @MainActor () -> Bool,
                                 legacy: @escaping @MainActor () async -> Void,
                                 group: @escaping @MainActor () async -> Void) async -> Bool {
        guard isCurrent() else { return false }
        await legacy()
        guard isCurrent() else { return false }
        await group()
        return isCurrent()
    }
    public static func disable(isCurrent: @escaping @MainActor () -> Bool,
                               group: @escaping @MainActor () async -> Void,
                               legacy: @escaping @MainActor () async -> Void) async {
        guard isCurrent() else { return }
        await group()
        guard isCurrent() else { return }
        await legacy()
    }
}
