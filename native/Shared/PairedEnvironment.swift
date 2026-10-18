import Foundation
import QuotaSync
import QuotaStore
import QuotaCore
import QuotaWidgets

public enum PairedEnvironment {
    public static var cfEnabled: Bool { UserDefaults(suiteName: group)?.bool(forKey: SyncPreferenceKeys.cloudflare) ?? false }
    public static var iCloudEnabled: Bool { UserDefaults(suiteName: group)?.bool(forKey: SyncPreferenceKeys.iCloud) ?? false }
    public static func setSyncEnabled(_ enabled: Bool, key: String) {
        UserDefaults(suiteName: group)?.set(enabled, forKey: key)
    }
    public static func iCloudCache() throws -> ICloudSnapshotCache {
        ICloudSnapshotCache(directory: try directory(), vault: vault)
    }
    public static func cachedSelection(cf: Snapshot?) async -> Snapshot? {
        var candidates: [Snapshot] = []
        if cfEnabled, let cf { candidates.append(cf) }
        if iCloudEnabled {
            let service = ICloudSnapshotSync()
            // Never show a previous account's cache on a cold/offline process launch.
            if let account = try? await service.accountIdentifier(),
               let cached = try? iCloudCache().load(accountID: account) { candidates.append(cached) }
        }
        return SyncSnapshotSelection.newest(candidates)
    }
    private static let widgetWindowKey = "quota-island.widget-window-id.v1"
    public static var group: String { Bundle.main.object(forInfoDictionaryKey: "QuotaAppGroup") as? String ?? "" }
    public static var accessGroup: String? { Bundle.main.object(forInfoDictionaryKey: "QuotaKeychainGroup") as? String }
    public static var vault: KeychainVault { KeychainVault(accessGroup: accessGroup) }
    public static func credentials() throws -> ViewerCredentials { try JSONDecoder().decode(ViewerCredentials.self, from: vault.load("viewer")) }
    public static func directory() throws -> URL {
        guard group.hasPrefix("group."), let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw SyncError.configuration }
        return root.appendingPathComponent("QuotaIsland")
    }
    public static func client(_ credentials: ViewerCredentials) throws -> SnapshotClient {
        SnapshotClient(transport: try SyncTransport(baseURL: credentials.endpoint), cache: try VerifiedCache(directory: directory(), trust: credentials.trust), token: credentials.token, key: .init(data: credentials.snapshotKey))
    }
    public static func usageClient(_ credentials: ViewerCredentials) throws -> UsageSnapshotClient {
        UsageSnapshotClient(transport: try SyncTransport(baseURL: credentials.endpoint),
                            cache: try VerifiedUsageCache(directory: directory(), trust: credentials.trust),
                            token: credentials.token, key: .init(data: credentials.snapshotKey))
    }
    public static func widgetWindowID() throws -> String? {
        let preferences = try widgetPreferences()
        guard let value = preferences.string(forKey: widgetWindowKey) else { return nil }
        guard !value.isEmpty, value.utf8.count <= 160, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SyncError.configuration }
        return value
    }
    public static func setWidgetWindowID(_ windowID: String?) throws {
        let preferences = try widgetPreferences()
        if let windowID {
            guard !windowID.isEmpty, windowID.utf8.count <= 160,
                  !windowID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SyncError.configuration }
            preferences.set(windowID, forKey: widgetWindowKey)
        } else {
            preferences.removeObject(forKey: widgetWindowKey)
        }
    }
    private static let widgetWindowsKey = "quota-island.widget-window-ids.v2"
    /// App defaults and each widget instance share the same two-quota limit.
    public static let maximumWidgetWindowIDs = WidgetSelectionPolicy.maximumWindowCount

    public static func widgetWindowIDs() throws -> [String] {
        let preferences = try widgetPreferences()
        guard let ids = preferences.stringArray(forKey: widgetWindowsKey) else {
            return try widgetWindowID().map { [$0] } ?? []
        }
        // Accept the previous six-item format, keeping its first two unique choices.
        guard ids.count <= 6,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw SyncError.configuration }
        return WidgetSelectionPolicy.resolve(configured: ids, defaults: [])
    }

    public static func setWidgetWindowIDs(_ ids: [String]) throws {
        guard ids.count <= Self.maximumWidgetWindowIDs, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw SyncError.configuration }
        let preferences = try widgetPreferences()
        try setWidgetWindowID(ids.first)
        preferences.set(ids, forKey: widgetWindowsKey)
    }

    public static func setWidgetWindowChoices(_ windows: [QuotaWindow]) throws {
        // AppIntent choices live in plaintext App Group preferences. Keep only
        // the IDs required to resolve a choice and anonymous display labels.
        let accounts = Array(Set(windows.map { $0.providerId + "/" + $0.accountId })).sorted()
        let ordinal = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element, $0.offset + 1) })
        let descriptors = windows.prefix(200).map { window in
            WidgetWindowDescriptor(window: window,
                                   accountOrdinal: ordinal[window.providerId + "/" + window.accountId] ?? 1)
        }
        let data = try JSONEncoder().encode(descriptors)
        guard data.count <= 128 * 1024 else { throw SyncError.configuration }
        let preferences = try widgetPreferences()
        preferences.set(data, forKey: WidgetWindowDescriptor.preferencesKey)
    }
    public static func clearWidgetWindowChoices() throws {
        let preferences = try widgetPreferences()
        preferences.removeObject(forKey: WidgetWindowDescriptor.preferencesKey)
        preferences.removeObject(forKey: widgetWindowKey)
        preferences.removeObject(forKey: widgetWindowsKey)
    }
    private static func widgetPreferences() throws -> UserDefaults {
        guard group.hasPrefix("group."),
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let preferences = UserDefaults(suiteName: group) else { throw SyncError.configuration }
        return preferences
    }
}
