@testable import QuotaProviders
import XCTest

final class ConnectionConfigurationTests: XCTestCase {
    /// Persistence tests decode a synthetic executable record. This never
    /// approves or launches a test binary as a production Codex CLI.
    private func approvedExecutable() throws -> ApprovedExecutable {
        try JSONDecoder().decode(ApprovedExecutable.self,
            from: Data(#"{"path":"file:///usr/bin/true","digest":"AA=="}"#.utf8))
    }

    func testVersionThreeManualProviderRecordsAreRemovedDuringMigration() throws {
        let fingerprint = String(repeating: "a", count: 64)
        let json = """
        {
          "version": 3,
          "deviceID": "device-1",
          "epoch": "epoch-1",
          "connections": [{
            "id": "legacy-openrouter",
            "kind": "native_provider",
            "providerID": "openrouter",
            "accountID": "account-1",
            "accountAlias": "OpenRouter",
            "expectedIdentity": "\(fingerprint)",
            "credential": {
              "keychainAccount": "legacy-keychain-item",
              "fingerprint": "\(fingerprint)",
              "source": "api"
            }
          }]
        }
        """

        let migrated = try ProviderConnectionsConfiguration.decodeMigrating(Data(json.utf8))
        XCTAssertTrue(migrated.migrated)
        XCTAssertEqual(migrated.configuration.version, ProviderConnectionsConfiguration.currentVersion)
        XCTAssertTrue(migrated.configuration.connections.isEmpty)
        XCTAssertEqual(migrated.configuration.pendingLegacyCredentialRemovals, ["legacy-keychain-item"])
    }

    func testRetiredKindsAreDroppedWhileNativeCodexSurvivesMigration() throws {
        let fingerprint = String(repeating: "b", count: 64)
        let instance = UUID().uuidString
        let codexRecord = ProviderConnectionRecord(
            id: "native-codex-kept", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "codex", accountID: "account-1", accountAlias: "Codex",
            expectedIdentity: fingerprint, instanceID: instance)
        let retired = """
        {
          "id": "retired-bridge", "kind": "codexbar",
          "providerID": "codex", "accountID": "account-2", "accountAlias": "Codex",
          "expectedIdentity": "\(String(repeating: "c", count: 64))", "isEnabled": true
        }
        """
        let codexJSON = String(decoding: try JSONEncoder().encode(codexRecord), as: UTF8.self)
        let json = """
        {
          "version": 8,
          "deviceID": "device-1",
          "epoch": "epoch-1",
          "connections": [\(retired), \(codexJSON)]
        }
        """

        let migrated = try ProviderConnectionsConfiguration.decodeMigrating(Data(json.utf8))
        XCTAssertTrue(migrated.migrated)
        XCTAssertEqual(migrated.configuration.connections.map(\.id), ["native-codex-kept"])
        XCTAssertEqual(migrated.configuration.connections.first?.instanceID, instance)
        XCTAssertTrue(try XCTUnwrap(migrated.configuration.connections.first).isEnabled)
    }

    func testPre9CodexAmbientRecordSurvivesMigrationNatively() throws {
        let fingerprint = String(repeating: "c", count: 64)
        let json = """
        {
          "version": 8,
          "deviceID": "device-1",
          "epoch": "epoch-1",
          "connections": [{
            "id": "local-codex-legacy", "kind": "codex_local_login",
            "providerID": "codex", "accountID": "account-2", "accountAlias": "Codex",
            "expectedIdentity": "\(fingerprint)", "isEnabled": true
          }]
        }
        """
        let migrated = try ProviderConnectionsConfiguration.decodeMigrating(Data(json.utf8))
        XCTAssertTrue(migrated.migrated)
        let record = try XCTUnwrap(migrated.configuration.connections.first)
        XCTAssertEqual(record.kind, .codexLocalLogin)
        XCTAssertEqual(record.accountID, "account-2")
        XCTAssertTrue(record.isEnabled, "ambient logins must not be parked as standalone")
        XCTAssertFalse(migrated.migrated && false)
    }

    func testPre9GrokAmbientRecordWithExecutableIsDroppedForRecovery() throws {
        let fingerprint = String(repeating: "d", count: 64)
        let json = """
        {
          "version": 8,
          "deviceID": "device-1",
          "epoch": "epoch-1",
          "connections": [{
            "id": "local-grok-legacy", "kind": "grok_local_login",
            "providerID": "grok", "accountID": "native-95770457", "accountAlias": "Grok",
            "expectedIdentity": "\(fingerprint)", "isEnabled": true,
            "executable": {"path": "/usr/local/bin/grok", "digest": "AA=="}
          }]
        }
        """
        let migrated = try ProviderConnectionsConfiguration.decodeMigrating(Data(json.utf8))
        XCTAssertTrue(migrated.migrated)
        XCTAssertTrue(migrated.configuration.connections.isEmpty,
                      "the executable-carrying shape is retired; startup recovery recreates it")
    }

    func testVersionEightStandaloneRecordIsRetainedButDisabled() throws {
        let record = ProviderConnectionRecord(
            id: "native-codex-standalone", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "codex", accountID: "account-1", accountAlias: "Codex",
            expectedIdentity: String(repeating: "d", count: 64))
        let encoded = try JSONEncoder().encode(ProviderConnectionsConfiguration(
            deviceID: "device-1", epoch: "epoch-1", connections: [record], version: 8))

        let migrated = try ProviderConnectionsConfiguration.decodeMigrating(encoded)
        XCTAssertTrue(migrated.migrated)
        let migratedRecord = try XCTUnwrap(migrated.configuration.connections.first)
        XCTAssertFalse(migratedRecord.isEnabled)
        XCTAssertNil(migratedRecord.instanceID)
        XCTAssertEqual(migratedRecord.providerID, "codex")
    }

    func testInstanceSwitchAndLegacyDefaultsSurviveRestart() throws {
        let record = ProviderConnectionRecord(id: "work", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "codex", accountID: "work-account", accountAlias: "Work", expectedIdentity: String(repeating: "b", count: 64),
            isEnabled: false, instanceID: UUID().uuidString)
        let data = try JSONEncoder().encode(record.validated())
        let restored = try JSONDecoder().decode(ProviderConnectionRecord.self, from: data)
        XCTAssertFalse(restored.isEnabled)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isEnabled")
        let old = try JSONDecoder().decode(ProviderConnectionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(old.isEnabled)
        let second = ProviderConnectionRecord(id: "personal", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "codex", accountID: "personal-account", accountAlias: "Personal", expectedIdentity: String(repeating: "c", count: 64),
            instanceID: UUID().uuidString)
        XCTAssertNoThrow(try ProviderConnectionsConfiguration(deviceID: "mac", epoch: "epoch", connections: [record, second]).validated())
        XCTAssertThrowsError(try ProviderConnectionsConfiguration(deviceID: "mac", epoch: "epoch", connections: [record, record]).validated())
    }

    func testOwnedInstanceSurvivesRestartAndCleanupCannotTargetActiveInstance() throws {
        let instance = UUID().uuidString
        let record = ProviderConnectionRecord(id: "personal", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "codex", accountID: "personal-account", accountAlias: "Personal",
            expectedIdentity: String(repeating: "d", count: 64), instanceID: instance)
        let pending = UUID().uuidString
        let config = ProviderConnectionsConfiguration(deviceID: "mac", epoch: "epoch", connections: [record],
            pendingInstanceRemovals: [pending])
        let decoded = try ProviderConnectionsConfiguration.decodeMigrating(JSONEncoder().encode(config.validated()))
        XCTAssertFalse(decoded.migrated)
        XCTAssertTrue(try XCTUnwrap(decoded.configuration.connections.first).isEnabled)
        XCTAssertEqual(decoded.configuration.connections.first?.instanceID, instance)
        XCTAssertEqual(decoded.configuration.pendingInstanceRemovals, [pending])
        var invalid = config
        invalid.pendingInstanceRemovals = [instance]
        XCTAssertThrowsError(try invalid.validated())
        invalid.pendingInstanceRemovals = ["../ambient"]
        XCTAssertThrowsError(try invalid.validated())
    }

    func testNativeCodexRecordRequiresExecutableAndCodexProviderID() throws {
        let fingerprint = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try ProviderConnectionRecord(id: "r1", kind: .nativeCodex, providerID: "codex",
            accountID: "account-1", accountAlias: "Codex", expectedIdentity: fingerprint).validated())
        XCTAssertThrowsError(try ProviderConnectionRecord(id: "r2", kind: .nativeCodex, executable: try approvedExecutable(),
            providerID: "amp", accountID: "account-1", accountAlias: "Amp",
            expectedIdentity: fingerprint, instanceID: UUID().uuidString).validated())
    }

    func testVersionEightAPIProviderRecordSurvivesMigration() throws {
        let instance = UUID().uuidString
        let record = ProviderConnectionRecord(id: "native-abc", kind: .nativeProvider, providerID: "openrouter",
            accountID: "native-abc-account", accountAlias: "OpenRouter",
            expectedIdentity: String(repeating: "f", count: 64), isEnabled: true, instanceID: instance)
        let encoded = try JSONEncoder().encode(ProviderConnectionsConfiguration(
            deviceID: "device-1", epoch: "epoch-1", connections: [record], version: 8))

        let decoded = try ProviderConnectionsConfiguration.decodeMigrating(encoded)
        XCTAssertTrue(decoded.migrated)
        XCTAssertEqual(decoded.configuration.version, ProviderConnectionsConfiguration.currentVersion)
        let restored = try XCTUnwrap(decoded.configuration.connections.first)
        XCTAssertEqual(restored.kind, .nativeProvider)
        XCTAssertEqual(restored.instanceID, instance)
        XCTAssertTrue(restored.isEnabled)
    }

    func testCurrentVersionAPIRecordRoundTripsUnchanged() throws {
        let record = ProviderConnectionRecord(id: "native-abc", kind: .nativeProvider, providerID: "amp",
            accountID: "native-abc-account", accountAlias: "Amp",
            expectedIdentity: String(repeating: "a", count: 64), instanceID: UUID().uuidString)
        let config = try ProviderConnectionsConfiguration(
            deviceID: "device-1", epoch: "epoch-1", connections: [record]).validated()
        let decoded = try ProviderConnectionsConfiguration.decodeMigrating(JSONEncoder().encode(config))
        XCTAssertFalse(decoded.migrated)
        XCTAssertEqual(decoded.configuration.connections.count, 1)
    }

    func testLegacyCleanupRejectsUntrustedKeychainReference() {
        XCTAssertThrowsError(try LegacyProviderSecretCleanup().remove(reference: "../../other-item"))
    }
}
