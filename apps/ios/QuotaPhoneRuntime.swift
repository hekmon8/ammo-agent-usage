import Foundation
import QuotaCore

/// App Group is mandatory for cache sharing. There is deliberately no fallback to a
/// private Documents or temporary directory, which would leave widgets with stale or
/// different data.
public struct AppGroupCacheConfiguration: Sendable, Equatable {
    public let identifier: String
    public let cacheDirectoryName: String

    public init(identifier: String, cacheDirectoryName: String = "QuotaIsland") {
        self.identifier = identifier
        self.cacheDirectoryName = cacheDirectoryName
    }

    public func cacheDirectory(fileManager: FileManager = .default) throws -> URL {
        guard identifier.hasPrefix("group."),
              cacheDirectoryName.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { throw AppGroupCacheError.unavailable }
        return container.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }
}

public enum AppGroupCacheError: Error, Equatable, Sendable {
    case unavailable
}

/// Pairing metadata may live in the App Group. It contains no snapshot plaintext,
/// symmetric key, Provider credential, OAuth token, or browser data.
public struct PairedCacheConfiguration: Sendable, Equatable {
    public let appGroup: AppGroupCacheConfiguration
    public let keychainAccount: String

    public init(appGroup: AppGroupCacheConfiguration, keychainAccount: String) {
        self.appGroup = appGroup
        self.keychainAccount = keychainAccount
    }
}

/// A narrow boundary used by the SwiftUI host. Concrete implementations must read
/// from `VerifiedCache`; callers must not substitute an unverified JSON cache.
public protocol VerifiedSnapshotReading: Sendable {
    func latestVerifiedSnapshot() async throws -> Snapshot?
}

/// The host may request foreground refreshes or read the last accepted snapshot.
/// Foreground scheduling belongs to the host; this reader never creates background
/// polling or a Provider connection.
public protocol PhoneSnapshotRefreshing: VerifiedSnapshotReading {
    func refreshFromPairedSource() async throws -> Snapshot?
}

public enum SnapshotKeychainError: Error, Equatable, Sendable {
    case unavailable
    case invalidKey
}

#if canImport(QuotaSync)
import CryptoKit
import QuotaSync

/// Bridges the UI to QuotaSync without weakening its encrypted, signed cache
/// boundary. The `SnapshotClient` itself enforces the ten-second single-flight
/// request rule and verifies an incoming envelope before replacing its cache.
public actor PairedSnapshotReader: PhoneSnapshotRefreshing {
    private let client: SnapshotClient

    public init(client: SnapshotClient) { self.client = client }

    public func latestVerifiedSnapshot() async throws -> Snapshot? {
        try await client.cached()
    }

    public func refreshFromPairedSource() async throws -> Snapshot? {
        try await client.refresh()
    }
}

/// Constructs `VerifiedCache` only at the explicit App Group location. The caller
/// supplies the pairing trust and a 32-byte Keychain key; no plaintext mirror is
/// created for the phone or its widget extension.
public enum PairedCacheFactory {
    public static func makeVerifiedCache(configuration: AppGroupCacheConfiguration, trust: SourceTrust) throws -> VerifiedCache {
        try VerifiedCache(directory: configuration.cacheDirectory(), trust: trust)
    }

    public static func makeSnapshotClient(
        configuration: AppGroupCacheConfiguration,
        trust: SourceTrust,
        endpoint: URL,
        readToken: String,
        keyData: Data
    ) throws -> SnapshotClient {
        guard keyData.count == 32 else { throw SnapshotKeychainError.invalidKey }
        return SnapshotClient(
            transport: try SyncTransport(baseURL: endpoint),
            cache: try makeVerifiedCache(configuration: configuration, trust: trust),
            token: readToken,
            key: SymmetricKey(data: keyData)
        )
    }
}
#endif

#if os(iOS)
import Security

/// Stores the pairing-derived symmetric key only in the iOS Keychain. The key is
/// inaccessible before the first user unlock, so the UI can honestly display locked.
public struct SnapshotKeychain {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String = "QuotaIsland.snapshot-key", account: String, accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }

    public func load() throws -> Data {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw SnapshotKeychainError.unavailable }
        guard data.count == 32 else { throw SnapshotKeychainError.invalidKey }
        return data
    }

    public func save(_ data: Data) throws {
        guard data.count == 32 else { throw SnapshotKeychainError.invalidKey }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let replacement: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SnapshotKeychainError.unavailable }
        var item = query
        replacement.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SnapshotKeychainError.unavailable }
    }
}
#endif
