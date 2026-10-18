import Foundation

public enum ProviderConnectionKind: String, Codable, Sendable {
    case nativeCodex = "native_codex"
    case nativeProvider = "native_provider"
    case codexLocalLogin = "codex_local_login"
    case grokLocalLogin = "grok_local_login"
    case claudeLocalLogin = "claude_local_login"
    case workbuddyLocalLogin = "workbuddy_local_login"
    case zcodeLocalLogin = "zcode_local_login"
    case githubCLILogin = "github_cli_login"

    /// Ambient-login records own no instance profile; the standalone-pause
    /// rule must not park them.
    public var usesLocalLogin: Bool {
        self == .codexLocalLogin || self == .grokLocalLogin || self == .claudeLocalLogin || self == .workbuddyLocalLogin || self == .zcodeLocalLogin || self == .githubCLILogin
    }
}

public struct ProviderConnectionRecord: Codable, Sendable {
    public let id: String
    public let kind: ProviderConnectionKind
    public let executable: ApprovedExecutable?
    public let providerID: String
    public let accountID: String
    public let accountAlias: String
    public let expectedIdentity: String
    public var isEnabled: Bool
    public let sourceAccountID: String?
    public let instanceID: String?
    public let organizationID: String?

    public init(id: String, kind: ProviderConnectionKind, executable: ApprovedExecutable? = nil, providerID: String,
                accountID: String, accountAlias: String, expectedIdentity: String,
                isEnabled: Bool = true, sourceAccountID: String? = nil, instanceID: String? = nil, organizationID: String? = nil) {
        self.id = id
        self.kind = kind
        self.executable = executable
        self.providerID = providerID
        self.accountID = accountID
        self.accountAlias = accountAlias
        self.expectedIdentity = expectedIdentity
        self.isEnabled = isEnabled
        self.sourceAccountID = sourceAccountID
        self.instanceID = instanceID
        self.organizationID = organizationID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, executable, providerID, accountID, accountAlias, expectedIdentity, isEnabled, sourceAccountID, instanceID, organizationID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: try values.decode(ProviderConnectionKind.self, forKey: .kind),
            executable: try values.decodeIfPresent(ApprovedExecutable.self, forKey: .executable),
            providerID: try values.decode(String.self, forKey: .providerID),
            accountID: try values.decode(String.self, forKey: .accountID),
            accountAlias: try values.decode(String.self, forKey: .accountAlias),
            expectedIdentity: try values.decode(String.self, forKey: .expectedIdentity),
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            sourceAccountID: try values.decodeIfPresent(String.self, forKey: .sourceAccountID),
            instanceID: try values.decodeIfPresent(String.self, forKey: .instanceID),
            organizationID: try values.decodeIfPresent(String.self, forKey: .organizationID))
    }

    public func validated() throws -> ProviderConnectionRecord {
        guard id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              accountID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              expectedIdentity.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !accountAlias.isEmpty, accountAlias.count <= 48 else { throw ProviderFailure.parseChanged }
        if let instanceID {
            guard UUID(uuidString: instanceID)?.uuidString == instanceID else { throw ProviderFailure.parseChanged }
        }
        if let sourceAccountID {
            guard kind == .nativeProvider, let uuid = UUID(uuidString: sourceAccountID),
                  uuid.uuidString == sourceAccountID else {
                throw ProviderFailure.parseChanged
            }
        }
        if let organizationID {
            guard providerID == "github-actions", kind == .githubCLILogin || kind == .nativeProvider, GitHubBillingReader.validOwner(organizationID) else { throw ProviderFailure.parseChanged }
        }
        switch kind {
        case .nativeCodex:
            guard executable != nil, providerID == "codex" else {
                throw ProviderFailure.parseChanged
            }
        case .nativeProvider:
            guard executable == nil else { throw ProviderFailure.parseChanged }
            _ = try NativeProviderCatalog.validateAPI(providerID: providerID)
        case .codexLocalLogin:
            guard providerID == "codex", executable == nil, instanceID == nil else {
                throw ProviderFailure.parseChanged
            }
        case .grokLocalLogin:
            guard providerID == "grok", executable == nil, instanceID == nil else {
                throw ProviderFailure.parseChanged
            }
        case .claudeLocalLogin:
            guard providerID == "claude", executable == nil, instanceID == nil else {
                throw ProviderFailure.parseChanged
            }
        case .workbuddyLocalLogin:
            guard providerID == "workbuddy", executable == nil, instanceID == nil else {
                throw ProviderFailure.parseChanged
            }
        case .githubCLILogin:
            guard providerID == "github-actions", executable == nil, instanceID == nil else { throw ProviderFailure.parseChanged }
        case .zcodeLocalLogin:
            guard providerID == "zcode", executable == nil, instanceID == nil else {
                throw ProviderFailure.parseChanged
            }
        }
        return self
    }
}

public struct ProviderConnectionsConfiguration: Codable, Sendable {
    public static let currentVersion = 10
    public let version: Int
    public let deviceID: String
    public let epoch: String
    public var connections: [ProviderConnectionRecord]
    public var pendingLegacyCredentialRemovals: [String]?
    public var pendingInstanceRemovals: [String]?

    public init(
        deviceID: String,
        epoch: String,
        connections: [ProviderConnectionRecord],
        pendingLegacyCredentialRemovals: [String]? = nil,
        pendingInstanceRemovals: [String]? = nil,
        version: Int = Self.currentVersion)
    {
        self.version = version
        self.deviceID = deviceID
        self.epoch = epoch
        self.connections = connections
        self.pendingLegacyCredentialRemovals = pendingLegacyCredentialRemovals
        self.pendingInstanceRemovals = pendingInstanceRemovals
    }

    public func validated() throws -> ProviderConnectionsConfiguration {
        guard version == Self.currentVersion,
              deviceID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              epoch.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              connections.count <= 80 else { throw ProviderFailure.parseChanged }
        let pending = pendingLegacyCredentialRemovals ?? []
        guard pending.count <= 80,
              Set(pending).count == pending.count,
              pending.allSatisfy({
                  $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
              })
        else { throw ProviderFailure.parseChanged }
        let instances = pendingInstanceRemovals ?? []
        guard instances.count <= 80, Set(instances).count == instances.count,
              instances.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              Set(connections.compactMap(\.instanceID)).count == connections.compactMap(\.instanceID).count,
              Set(instances).isDisjoint(with: connections.compactMap(\.instanceID))
        else { throw ProviderFailure.parseChanged }
        var ids = Set<String>()
        var accounts = Set<String>()
        for connection in connections {
            _ = try connection.validated()
            guard ids.insert(connection.id).inserted,
                  accounts.insert(connection.providerID + "/" + connection.accountID).inserted else {
                throw ProviderFailure.parseChanged
            }
        }
        return self
    }

    public static func decodeMigrating(_ data: Data) throws -> (configuration: ProviderConnectionsConfiguration, migrated: Bool) {
        if let current = try? JSONDecoder().decode(ProviderConnectionsConfiguration.self, from: data) {
            return try migrate(current, candidates: current.connections, source: data)
        }
        // Releases before version 9 could persist connection kinds that are no
        // longer expressible. Decode leniently, drop those records, keep the rest.
        if let salvaged = try? JSONDecoder().decode(RetiredKindConfiguration.self, from: data) {
            let kept = salvaged.connections.compactMap { record -> ProviderConnectionRecord? in
                guard let kind = ProviderConnectionKind(rawValue: record.kind) else { return nil }
                return ProviderConnectionRecord(
                    id: record.id, kind: kind, executable: record.executable,
                    providerID: record.providerID, accountID: record.accountID,
                    accountAlias: record.accountAlias, expectedIdentity: record.expectedIdentity,
                    isEnabled: record.isEnabled ?? true, sourceAccountID: record.sourceAccountID,
                    instanceID: record.instanceID, organizationID: record.organizationID)
            }
            return try migrate(
                ProviderConnectionsConfiguration(
                    deviceID: salvaged.deviceID, epoch: salvaged.epoch, connections: kept,
                    pendingLegacyCredentialRemovals: salvaged.pendingLegacyCredentialRemovals,
                    pendingInstanceRemovals: salvaged.pendingInstanceRemovals,
                    version: salvaged.version),
                candidates: kept, source: data)
        }
        let legacy: LegacyConnection
        do { legacy = try JSONDecoder().decode(LegacyConnection.self, from: data) }
        catch { throw ProviderFailure.parseChanged }
        let id = "native-codex-" + String(legacy.identity.prefix(24))
        let record = ProviderConnectionRecord(
            id: id, kind: .nativeCodex, executable: legacy.executable, providerID: "codex",
            accountID: legacy.accountID, accountAlias: "Codex", expectedIdentity: legacy.identity, isEnabled: false)
        return (try ProviderConnectionsConfiguration(deviceID: legacy.deviceID, epoch: legacy.epoch, connections: [record]).validated(), true)
    }

    private static func migrate(_ current: ProviderConnectionsConfiguration,
                                candidates: [ProviderConnectionRecord], source: Data) throws -> (ProviderConnectionsConfiguration, Bool) {
        guard [Self.currentVersion, 2, 3, 4, 5, 6, 7, 8, 9].contains(current.version),
              current.deviceID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              current.epoch.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              candidates.count <= 80 else { throw ProviderFailure.parseChanged }
        var valid: [ProviderConnectionRecord] = []
        var ids = Set<String>()
        var accounts = Set<String>()
        for var connection in candidates {
            // Version 3 kept keychain references that were migrated out; those
            // records never owned a vault instance, so they stay retired.
            if current.version < 4, connection.kind == .nativeProvider { continue }
            // Standalone records predate per-instance profiles and must be
            // reconnected explicitly before they can fetch again. Ambient-login
            // records never own an instance and stay enabled.
            if connection.instanceID == nil, !connection.kind.usesLocalLogin { connection.isEnabled = false }
            guard (try? connection.validated()) != nil,
                  ids.insert(connection.id).inserted,
                  accounts.insert(connection.providerID + "/" + connection.accountID).inserted else { continue }
            valid.append(connection)
        }
        guard current.version < Self.currentVersion || candidates.isEmpty || !valid.isEmpty else {
            throw ProviderFailure.parseChanged
        }
        let migrated = try ProviderConnectionsConfiguration(
            deviceID: current.deviceID,
            epoch: current.epoch,
            connections: valid,
            pendingLegacyCredentialRemovals: current.version < 4
                ? legacyCredentialReferences(in: source)
                : current.pendingLegacyCredentialRemovals,
            pendingInstanceRemovals: current.pendingInstanceRemovals).validated()
        return (migrated,
                current.version != Self.currentVersion || valid.count != candidates.count || candidates.contains { $0.instanceID == nil && !$0.kind.usesLocalLogin && $0.isEnabled })
    }

    private struct LegacyConnection: Codable {
        let executable: ApprovedExecutable
        let accountID: String
        let identity: String
        let deviceID: String
        let epoch: String
    }

    /// Shape of configuration files written by releases that still carried
    /// retired connection kinds; only used to salvage the surviving records.
    /// that remain expressible.
    private struct RetiredKindConfiguration: Decodable {
        struct Record: Decodable {
            let id: String
            let kind: String
            let executable: ApprovedExecutable?
            let providerID: String
            let accountID: String
            let accountAlias: String
            let expectedIdentity: String
            let isEnabled: Bool?
            let sourceAccountID: String?
            let instanceID: String?
            let organizationID: String?
        }
        let version: Int
        let deviceID: String
        let epoch: String
        let connections: [Record]
        let pendingLegacyCredentialRemovals: [String]?
        let pendingInstanceRemovals: [String]?
    }

    private struct LegacyConfiguration: Decodable {
        struct Connection: Decodable {
            struct Credential: Decodable { let keychainAccount: String }
            let credential: Credential?
        }
        let connections: [Connection]
    }

    private static func legacyCredentialReferences(in data: Data) -> [String]? {
        guard let decoded = try? JSONDecoder().decode(LegacyConfiguration.self, from: data) else { return nil }
        var seen = Set<String>()
        let references = decoded.connections.compactMap(\.credential?.keychainAccount).filter { reference in
            reference.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil &&
                seen.insert(reference).inserted
        }
        return references.isEmpty ? nil : references
    }
}
