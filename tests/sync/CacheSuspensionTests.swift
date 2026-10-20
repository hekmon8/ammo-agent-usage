import CryptoKit
import Foundation
import XCTest
import QuotaCore
import QuotaStore
@testable import QuotaSync

final class CacheSuspensionTests: XCTestCase {
    func testStoredQuotaEnvelopeIsValidatedOutsideBusyLockAndPreservedOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedCache(directory: root, trust: trust)
        let directory = await cache.directory
        let file = directory.appendingPathComponent("verified-envelope.json")
        let existing = Data("{}".utf8)
        try PrivateFile.write(existing, to: file)
        let otherProcess = try FileTransaction(directory: directory, name: "verified-cache")
        defer { withExtendedLifetime(otherProcess) {} }
        let snapshot = try Snapshot.make(windows: [], deviceID: "mac", epoch: "epoch", sequence: 2, capturedAt: Date())
        let incoming = try EnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        do { _ = try await cache.accept(incoming, key: key); XCTFail("Replaced invalid stored ciphertext") }
        catch { XCTAssertEqual(error as? SyncError, .invalidEnvelope, "The crash's previous-envelope validation path must run before locking") }
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), existing)
    }

    func testStoredUsageEnvelopeIsValidatedOutsideBusyLockAndPreservedOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedUsageCache(directory: root, trust: trust)
        let directory = await cache.directory
        let file = directory.appendingPathComponent("verified-usage-envelope.json")
        let existing = Data("{}".utf8)
        try PrivateFile.write(existing, to: file)
        let otherProcess = try FileTransaction(directory: directory, name: "verified-usage-cache")
        defer { withExtendedLifetime(otherProcess) {} }
        let snapshot = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 2,
            capturedAt: "2026-10-15T08:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-01",
            sources: [TokenUsageSource(agent: .codex, status: .available)], buckets: [])
        let incoming = try UsageEnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        do { _ = try await cache.accept(incoming, key: key); XCTFail("Replaced invalid stored usage ciphertext") }
        catch { XCTAssertEqual(error as? SyncError, .invalidEnvelope) }
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), existing)
    }

    func testInvalidQuotaEnvelopeDoesNotWaitForAnotherProcessFileLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey()
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedCache(directory: root, trust: trust)
        let directory = await cache.directory
        let otherProcess = try FileTransaction(directory: directory, name: "verified-cache")
        defer { withExtendedLifetime(otherProcess) {} }
        do {
            _ = try await cache.accept(Data("{}".utf8), key: SymmetricKey(size: .bits256))
            XCTFail("Invalid input was accepted")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidEnvelope, "Authentication/validation must precede any file lock, including a busy one")
        }
    }

    func testInvalidUsageEnvelopeDoesNotWaitForAnotherProcessFileLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey()
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let cache = try VerifiedUsageCache(directory: root, trust: trust)
        let directory = await cache.directory
        let otherProcess = try FileTransaction(directory: directory, name: "verified-usage-cache")
        defer { withExtendedLifetime(otherProcess) {} }
        do {
            _ = try await cache.accept(Data("{}".utf8), key: SymmetricKey(size: .bits256))
            XCTFail("Invalid input was accepted")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidEnvelope, "Usage validation must not run inside a file transaction either")
        }
    }

    func testIndependentQuotaCachesCannotRegressEachOthersSequence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let caches = try (0..<4).map { _ in try VerifiedCache(directory: root, trust: trust) }
        var envelopes: [Data] = []
        for sequence in 1...24 {
            let snapshot = try Snapshot.make(windows: [], deviceID: "mac", epoch: "epoch", sequence: Int64(sequence), capturedAt: Date())
            envelopes.append(try EnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer))
        }
        let inputs = envelopes
        let accepted = await withTaskGroup(of: Int64?.self) { group in
            for index in inputs.indices {
                group.addTask {
                    do { return try await caches[index % caches.count].accept(inputs[index], key: key).sourceSequence }
                    catch SyncError.replay { return nil }
                    catch StoreError.conflict { return nil }
                    catch { XCTFail("Unexpected cache admission failure: \(error)"); return nil }
                }
            }
            var values: [Int64] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        XCTAssertFalse(accepted.isEmpty)
        let final = try await caches[0].latest(key: key)
        XCTAssertEqual(final?.sourceSequence, accepted.max())
        _ = try await caches[1].accept(inputs.last!, key: key)
        let highest = try await caches[2].latest(key: key)
        XCTAssertEqual(highest?.sourceSequence, 24)
        do { _ = try await caches[3].accept(inputs[0], key: key); XCTFail("Accepted replay after concurrent admission") }
        catch SyncError.replay {}
    }

    func testCancelledQuotaAndUsageAdmissionPreservesLastGoodCiphertext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let quota = try VerifiedCache(directory: root, trust: trust)
        let usage = try VerifiedUsageCache(directory: root, trust: trust)
        let snapshot = try Snapshot.make(windows: [], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: Date())
        let bytes = try EnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        _ = try await quota.accept(bytes, key: key)
        let directory = await quota.directory
        let file = directory.appendingPathComponent("verified-envelope.json")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var cancellations = 0
            do { _ = try await quota.accept(bytes, key: key) } catch is CancellationError { cancellations += 1 } catch {}
            do { _ = try await usage.accept(Data("{}".utf8), key: key) } catch is CancellationError { cancellations += 1 } catch {}
            return cancellations
        }.value
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 262_144), bytes)
        let noUsage = try await usage.latest(key: key)
        XCTAssertNil(noUsage)
    }

    func testIndependentUsageCachesRejectConflictingSameSequenceAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let trust = SourceTrust(workspaceID: "ws", deviceID: "mac", epoch: "epoch", keyID: "key", publicKey: signer.publicKey.rawRepresentation)
        let first = try VerifiedUsageCache(directory: root, trust: trust)
        let second = try VerifiedUsageCache(directory: root, trust: trust)
        let snapshot = TokenUsageSnapshot(sourceDeviceId: "mac", sourceEpoch: "epoch", sourceSequence: 2,
            capturedAt: "2026-10-15T08:00:00Z", timeZoneIdentifier: "Etc/UTC", retainedFromDay: "2026-10-01",
            sources: [TokenUsageSource(agent: .codex, status: .available)], buckets: [])
        let a = try UsageEnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        let b = try UsageEnvelopeCodec.seal(snapshot, workspaceID: "ws", keyID: "key", key: key, signingKey: signer)
        let count = await withTaskGroup(of: Bool.self) { group in
            for (cache, data) in [(first, a), (second, b)] {
                group.addTask {
                    do { _ = try await cache.accept(data, key: key); return true }
                    catch SyncError.replay { return false }
                    catch { XCTFail("Unexpected usage admission failure: \(error)"); return false }
                }
            }
            var successes = 0
            for await accepted in group { if accepted { successes += 1 } }
            return successes
        }
        XCTAssertEqual(count, 1)
        let directory = await first.directory
        let saved = try PrivateFile.read(directory.appendingPathComponent("verified-usage-envelope.json"), maxBytes: 262_144)
        XCTAssertTrue(saved == a || saved == b)
        let restored = try await second.latest(key: key)
        XCTAssertEqual(restored?.sourceSequence, 2)
    }
}
