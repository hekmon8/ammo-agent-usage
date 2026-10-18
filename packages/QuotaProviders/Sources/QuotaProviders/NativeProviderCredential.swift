import Foundation

/// A user-entered provider credential. Only ever lives in this app's Keychain;
/// connection records and public snapshots carry no credential material.
public struct NativeProviderCredential: Codable, Sendable, Equatable {
    public enum Kind: String, CaseIterable, Codable, Sendable, Hashable {
        case apiKey
        case cookie
        case oauth
    }

    public let kind: Kind
    public let value: String
    public let organizationID: String?
    public let workspaceID: String?
    public let region: String?

    public init(
        kind: Kind,
        value: String,
        organizationID: String? = nil,
        workspaceID: String? = nil,
        region: String? = nil)
    {
        self.kind = kind
        self.value = value
        self.organizationID = organizationID
        self.workspaceID = workspaceID
        self.region = region
    }

    public func validated() throws {
        guard value.count >= 8, value.count <= 8_192, !value.contains("\0"),
              value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        else { throw ProviderFailure.parseChanged }
        for optional in [organizationID, workspaceID, region] {
            guard let optional else { continue }
            guard optional.count <= 256, !optional.contains("\0"),
                  optional == optional.trimmingCharacters(in: .whitespacesAndNewlines), !optional.isEmpty
            else { throw ProviderFailure.parseChanged }
        }
    }
}
