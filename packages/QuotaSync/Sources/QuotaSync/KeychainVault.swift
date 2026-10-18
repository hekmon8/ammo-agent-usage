import Foundation
import Security

public enum VaultError: Error { case locked, unavailable, exists }
public protocol SecretStoring: Sendable {
    func load(_ account: String) throws -> Data
    func save(_ data: Data, account: String) throws
    func insert(_ data: Data, account: String) throws
    func contains(_ account: String) throws -> Bool
    func remove(_ account: String) throws
}
public extension SecretStoring {
    /// In-memory test stores may use this fallback; KeychainVault overrides it
    /// with the atomic SecItemAdd operation.
    func insert(_ data: Data, account: String) throws {
        do { _ = try load(account); throw VaultError.exists }
        catch VaultError.unavailable { try save(data, account: account) }
    }
    func contains(_ account: String) throws -> Bool {
        do { _ = try load(account); return true }
        catch VaultError.unavailable { return false }
    }
}
/// Sync-only material. Provider credentials are never imported here.
public struct KeychainVault: SecretStoring {
    public let service: String
    public let accessGroup: String?
    public init(service: String = "QuotaIsland.sync", accessGroup: String? = nil) { self.service = service; self.accessGroup = accessGroup }
    private func query(_ account: String) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        return result
    }
    public func load(_ account: String) throws -> Data {
        var values = query(account); values[kSecReturnData as String] = true; values[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let code = SecItemCopyMatching(values as CFDictionary, &item)
        if code == errSecInteractionNotAllowed { throw VaultError.locked }
        guard code == errSecSuccess, let data = item as? Data else { throw VaultError.unavailable }
        return data
    }
    public func remove(_ account: String) throws {
        let code = SecItemDelete(query(account) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw VaultError.unavailable }
    }
    public func save(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let code = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if code == errSecSuccess { return }
        guard code == errSecItemNotFound else { throw VaultError.unavailable }
        guard SecItemAdd(query(account).merging(values) { _, b in b } as CFDictionary, nil) == errSecSuccess else { throw VaultError.unavailable }
    }
    public func insert(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let code = SecItemAdd(query(account).merging(values) { _, b in b } as CFDictionary, nil)
        if code == errSecDuplicateItem { throw VaultError.exists }
        if code == errSecInteractionNotAllowed { throw VaultError.locked }
        guard code == errSecSuccess else { throw VaultError.unavailable }
    }
    public func contains(_ account: String) throws -> Bool {
        var values = query(account)
        values[kSecReturnAttributes as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let code = SecItemCopyMatching(values as CFDictionary, &item)
        if code == errSecSuccess { return true }
        if code == errSecItemNotFound { return false }
        if code == errSecInteractionNotAllowed { throw VaultError.locked }
        throw VaultError.unavailable
    }
}
