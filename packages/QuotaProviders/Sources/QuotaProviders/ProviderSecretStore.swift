import Foundation
import Security
import LocalAuthentication

public enum LegacyProviderSecretCleanupError: Error, Sendable {
    case invalidReference
    case unavailable
}

/// Delete-only access retained until every version 2/3 credential reference
/// has been durably migrated out of connection.json.
public struct LegacyProviderSecretCleanup: Sendable {
    private static let service = "QuotaIsland.providers"

    public init() {}

    public func remove(reference: String) throws {
        guard reference.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw LegacyProviderSecretCleanupError.invalidReference
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LegacyProviderSecretCleanupError.unavailable
        }
    }
}

/// Each item belongs to one local instance. No synchronizable or shared access group.
public struct ProviderInstanceVault: Sendable {
    private struct Envelope: Codable {
        let providerID: String
        let credential: NativeProviderCredential
    }
    public init() {}
    private func query(_ reference: String) throws -> [String: Any] {
        guard UUID(uuidString: reference)?.uuidString == reference else { throw ProviderFailure.parseChanged }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "QuotaIsland.provider-instances",
                kSecAttrAccount as String: reference,
                kSecAttrSynchronizable as String: false]
    }
    public func save(_ credential: NativeProviderCredential, providerID: String, reference: String) throws {
        let data = try JSONEncoder().encode(Envelope(providerID: providerID, credential: credential))
        guard data.count <= 131_072 else { throw ProviderFailure.outputLimit }
        var values = try query(reference)
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Draft IDs are fresh; never overwrite another instance's credential.
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw ProviderFailure.permissionDenied }
    }
    public func load(providerID: String, reference: String) throws -> NativeProviderCredential {
        var values = try query(reference)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        values[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 131_072,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.providerID == providerID else { throw ProviderFailure.authRequired }
        return envelope.credential
    }
    public func remove(reference: String) throws {
        let code = SecItemDelete(try query(reference) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw ProviderFailure.permissionDenied }
    }
}
