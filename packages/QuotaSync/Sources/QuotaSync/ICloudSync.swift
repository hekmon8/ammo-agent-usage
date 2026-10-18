import Foundation
import CloudKit
import CryptoKit
import Security
import OSLog
import QuotaCore
import QuotaStore

public enum SyncPreferenceKeys {
    public static let cloudflare = "quota.sync.cloudflare.enabled"
    public static let iCloud = "quota.sync.icloud.enabled"
}

/// Compare whole observations, never combine accounts or add provider percentages.
public enum SyncSnapshotSelection {
    public static func newest(_ candidates: [Snapshot]) -> Snapshot? {
        candidates.max {
            let a = QuotaRules.date($0.capturedAt) ?? .distantPast
            let b = QuotaRules.date($1.capturedAt) ?? .distantPast
            if a != b { return a < b }
            if $0.sourceDeviceId == $1.sourceDeviceId && $0.sourceEpoch == $1.sourceEpoch {
                return $0.sourceSequence < $1.sourceSequence
            }
            // Preserve caller priority for simultaneous observations (CF first on phone).
            return false
        }
    }
    public static func accepts(_ incoming: Snapshot, after current: Snapshot?) -> Bool {
        guard let current else { return true }
        if incoming.sourceDeviceId == current.sourceDeviceId && incoming.sourceEpoch == current.sourceEpoch {
            return incoming.sourceSequence >= current.sourceSequence
        }
        return (QuotaRules.date(incoming.capturedAt) ?? .distantPast) >= (QuotaRules.date(current.capturedAt) ?? .distantPast)
    }
}

public enum ICloudSyncError: Error { case configuration, accountUnavailable, invalidRecord, olderObservation, accountMismatch }

/// A single-record fetch can report its failure inside a batch-level partial error.
/// Only unwrap the requested record; an unrelated failure must never mean "empty".
enum ICloudRecordFailure {
    static func code(_ error: Error, recordID: CKRecord.ID) -> CKError.Code? {
        guard let cloud = error as? CKError else { return nil }
        if cloud.code == .partialFailure {
            guard let item = cloud.partialErrorsByItemID?[recordID] as? CKError else { return nil }
            return item.code
        }
        return cloud.code
    }
}

public enum ICloudSyncFeedback {
    /// Returns the key plus arguments, not rendered text, so callers holding the
    /// value across a language change can re-render it (`LocalizedStatus.text`).
    public static func message(for error: Error) -> LocalizedStatus {
        if let local = error as? ICloudSyncError {
            switch local {
            case .configuration: return LocalizedStatus("icloud.error.entitlement")
            case .accountUnavailable: return LocalizedStatus("icloud.error.accountUnavailable")
            case .accountMismatch: return LocalizedStatus("icloud.error.accountMismatch")
            case .olderObservation: return LocalizedStatus("icloud.error.olderObservation")
            case .invalidRecord: return LocalizedStatus("icloud.error.invalidRecord")
            }
        }
        guard let cloud = error as? CKError else { return LocalizedStatus("icloud.error.generic") }
        switch cloud.code {
        case .notAuthenticated: return LocalizedStatus("icloud.error.notAuthenticated")
        case .permissionFailure: return LocalizedStatus("icloud.error.permissionFailure")
        case .missingEntitlement, .badContainer, .badDatabase:
            return LocalizedStatus("icloud.error.entitlement")
        case .networkUnavailable, .networkFailure:
            return LocalizedStatus("icloud.error.network")
        case .quotaExceeded: return LocalizedStatus("icloud.error.quotaExceeded")
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return LocalizedStatus("icloud.error.busy")
        case .serverRejectedRequest: return LocalizedStatus("icloud.error.serverRejected")
        case .serverRecordChanged: return LocalizedStatus("icloud.error.serverRecordChanged")
        default: return LocalizedStatus("icloud.error.unknownCode", cloud.code.rawValue)
        }
    }
}

/// A private CloudKit record, accessible only to this Apple account. Quota payload is
/// an encrypted field; provider credentials never enter this API. Multiple Macs use
/// the latest complete observation, with optimistic locking to prevent stale writes.
public actor ICloudSnapshotSync {
    public static var hasMacCloudKitEntitlement: Bool {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String] else { return false }
        return services.contains("CloudKit")
        #else
        return true
        #endif
    }
    public static var containerIdentifier: String? {
        configuredContainerIdentifier(Bundle.main.object(forInfoDictionaryKey: "QuotaICloudContainer") as? String)
    }

    static func configuredContainerIdentifier(_ value: String?) -> String? {
        guard let value, value.hasPrefix("iCloud."), value.count > "iCloud.".count,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return nil }
        return value
    }

    private let container: CKContainer?
    private let recordID = CKRecord.ID(recordName: "latest-quota-v1")
    private var uploading = false

    public init(containerIdentifier: String? = ICloudSnapshotSync.containerIdentifier) {
        container = Self.configuredContainerIdentifier(containerIdentifier).map { CKContainer(identifier: $0) }
    }
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.example.ammo", category: "iCloud")

    private func configuredContainer() throws -> CKContainer {
        guard let container else { throw ICloudSyncError.configuration }
        return container
    }

    private func account() async throws -> CKRecord.ID {
        try Task.checkCancellation()
        let container = try configuredContainer()
        guard try await container.accountStatus() == .available else { throw ICloudSyncError.accountUnavailable }
        do { return try await container.userRecordID() }
        catch {
            logFailure(error, stage: "account")
            throw error
        }
    }
    private func logFailure(_ error: Error, stage: String) {
        // Never log descriptions, userInfo, account identifiers or quota payloads.
        let code = (error as? CKError)?.code.rawValue ?? -1
        let itemCode = ICloudRecordFailure.code(error, recordID: recordID)?.rawValue ?? -1
        logger.error("CloudKit stage=\(stage, privacy: .public) code=\(code, privacy: .public) itemCode=\(itemCode, privacy: .public)")
    }

    private func readRecord() async throws -> CKRecord {
        let container = try configuredContainer()
        let privateDatabase = container.privateCloudDatabase
        let publicDatabase = container.publicCloudDatabase
        let id = recordID
        do {
            return try await ICloudContainerRecovery.readRecord(
                fetch: { try await privateDatabase.record(for: id) },
                bootstrap: { _ = try await publicDatabase.allRecordZones() }
            )
        }
        catch {
            logFailure(error, stage: "fetch")
            if let cloud = error as? CKError, cloud.code == .partialFailure,
               let item = cloud.partialErrorsByItemID?[recordID] { throw item }
            throw error
        }
    }

    public func accountIdentifier() async throws -> String { try await account().recordName }
    public func upload(_ snapshot: Snapshot) async throws {
        // Collector callbacks are serialized, but explicit retries may overlap.
        guard !uploading else { throw SyncError.unavailable }
        uploading = true
        defer { uploading = false }
        let owner = try await account()
        let data = try SnapshotCodec.encode(snapshot)
        let database = try configuredContainer().privateCloudDatabase
        var record: CKRecord
        do { record = try await readRecord() }
        catch where ICloudRecordFailure.code(error, recordID: recordID) == .unknownItem {
            record = CKRecord(recordType: "QuotaSnapshot", recordID: recordID)
        }
        for attempt in 0..<3 {
            if let previous = record.encryptedValues["payload"] as? Data {
                guard SyncSnapshotSelection.accepts(snapshot, after: try SnapshotCodec.decode(previous)) else {
                    throw ICloudSyncError.olderObservation
                }
            }
            guard try await account() == owner else { throw ICloudSyncError.accountUnavailable }
            try Task.checkCancellation()
            record.encryptedValues["payload"] = data as CKRecordValue
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                // Re-evaluate the observation against the winning server record.
                if let server = error.serverRecord { record = server }
                else { record = try await readRecord() }
            } catch {
                logFailure(error, stage: "save")
                throw error
            }
        }
    }
    public func fetch(expectedAccount: String? = nil) async throws -> Snapshot? {
        let owner = try await account()
        if let expectedAccount, expectedAccount != owner.recordName { throw ICloudSyncError.accountMismatch }
        do {
            let record = try await readRecord()
            guard let data = record.encryptedValues["payload"] as? Data else { throw ICloudSyncError.invalidRecord }
            let snapshot = try SnapshotCodec.decode(data)
            guard try await account() == owner else { throw ICloudSyncError.accountUnavailable }
            return snapshot
        } catch where ICloudRecordFailure.code(error, recordID: recordID) == .unknownItem { return nil }
    }
}

/// Encrypted local mirror for iCloud observations, separate from CF trust/cache.
/// The app and widget share only a Keychain key and an App Group ciphertext file.
public struct ICloudSnapshotCache: Sendable {
    private let directory: URL
    private let vault: any SecretStoring
    public init(directory: URL, vault: any SecretStoring) { self.directory = directory; self.vault = vault }
    private var file: URL { directory.appendingPathComponent("icloud-snapshot.enc") }
    private func key(create: Bool) throws -> SymmetricKey {
        do {
            let data = try vault.load("icloud-cache-key")
            guard data.count == 32 else { throw ICloudSyncError.invalidRecord }
            return SymmetricKey(data: data)
        } catch VaultError.unavailable where create {
            let key = SymmetricKey(size: .bits256)
            try vault.save(key.withUnsafeBytes { Data($0) }, account: "icloud-cache-key")
            return key
        }
    }
    private struct Observation: Codable { let accountHash: String; let snapshot: Data }
    private func accountHash(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func save(_ snapshot: Snapshot, accountID: String) throws {
        let key = try key(create: true)
        let observation = Observation(accountHash: accountHash(accountID), snapshot: try SnapshotCodec.encode(snapshot))
        let sealed = try AES.GCM.seal(JSONEncoder().encode(observation), using: key)
        guard let data = sealed.combined else { throw ICloudSyncError.invalidRecord }
        try PrivateFile.write(data, to: file)
    }
    public func load(accountID: String) throws -> Snapshot {
        // The sealed observation JSON base64-encodes a full 128 KiB snapshot (~176 KB).
        let data = try PrivateFile.read(file, maxBytes: 262_144)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false))
        let observation = try JSONDecoder().decode(Observation.self, from: plaintext)
        guard observation.accountHash == accountHash(accountID) else { throw ICloudSyncError.accountMismatch }
        return try SnapshotCodec.decode(observation.snapshot)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
