import Darwin
import Foundation
import XCTest
@testable import QuotaStore

final class FileTransactionSuspensionTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var recorded: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private static func canTakeLock(_ file: URL) -> Bool {
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    func testExpiredAssertionEndsExactlyOnceAfterFileLockRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockFile = root.appendingPathComponent("cache.lock")
        let events = Events()
        let protection = FileTransactionProtection { events.append(Self.canTakeLock(lockFile)) }
        var transaction: FileTransaction? = try FileTransaction(directory: root, name: "cache", protection: protection)
        XCTAssertFalse(Self.canTakeLock(lockFile))
        protection.expire()
        XCTAssertThrowsError(try transaction?.checkCancellation()) { XCTAssertEqual($0 as? StoreError, .unavailable) }
        XCTAssertTrue(events.recorded.isEmpty, "Expiration must not end execution time while a file lock is held")
        transaction = nil
        protection.finish()
        XCTAssertEqual(events.recorded, [true], "End the assertion once, after flock and descriptor release")
    }

    func testAlreadyExpiredAssertionDeniesLockAdmissionAndKeepsData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.prepareDirectory(root)
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("last-good".utf8), to: file)
        let events = Events()
        let protection = FileTransactionProtection { events.append(true) }
        protection.expire()
        XCTAssertThrowsError(try FileTransaction(directory: root, name: "cache", protection: protection)) {
            XCTAssertEqual($0 as? StoreError, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.lock").path))
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("last-good".utf8))
        XCTAssertEqual(events.recorded, [true])
    }

    func testRejectedSecondOwnerCannotFinishAnActiveOwnersAssertion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        let protection = FileTransactionProtection { events.append(true) }
        var owner: FileTransaction? = try FileTransaction(directory: root, name: "cache", protection: protection)
        XCTAssertThrowsError(try FileTransaction(directory: root, name: "other", protection: protection))
        XCTAssertTrue(events.recorded.isEmpty)
        XCTAssertFalse(Self.canTakeLock(root.appendingPathComponent("cache.lock")))
        try owner?.checkCancellation()
        owner = nil
        XCTAssertEqual(events.recorded, [true])
    }

    func testExpirationInterruptsLockContentionWithoutReleasingOtherOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let otherOwner = try FileTransaction(directory: root, name: "cache")
        defer { withExtendedLifetime(otherOwner) {} }
        let events = Events()
        let lockFile = root.appendingPathComponent("cache.lock")
        let protection = FileTransactionProtection { events.append(Self.canTakeLock(lockFile)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { protection.expire() }
        let start = Date()
        XCTAssertThrowsError(try FileTransaction(directory: root, name: "cache", protection: protection)) {
            XCTAssertEqual($0 as? StoreError, .unavailable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "Do not consume the whole three-second lock timeout after expiration")
        XCTAssertEqual(events.recorded, [false], "Clean up only our assertion, never unlock another owner")
        XCTAssertFalse(Self.canTakeLock(lockFile))
    }

    func testInvalidTransactionConstructionEndsItsAssertion() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let events = Events()
        let protection = FileTransactionProtection { events.append(true) }
        XCTAssertThrowsError(try FileTransaction(directory: root, name: "../invalid", protection: protection))
        XCTAssertEqual(events.recorded, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPreparationHasNoLockAndConcurrentReplacementForcesFreshAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("old".utf8), to: file)
        var admitted: [String] = []
        let result = try OptimisticFileUpdate.update(at: file, lockName: "cache", maxBytes: 100) { previous in
            let value = String(decoding: previous!, as: UTF8.self)
            admitted.append(value)
            if admitted.count == 1 {
                // Simulate another app/extension writing during expensive validation.
                try FileTransaction.withLock(directory: root, name: "cache") { _ in
                    try PrivateFile.write(Data("competing".utf8), to: file)
                }
            }
            return (Data("accepted".utf8), value)
        }
        XCTAssertEqual(admitted, ["old", "competing"])
        XCTAssertEqual(result, "competing")
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("accepted".utf8))
    }

    func testPersistentContentionFailsBoundedlyWithoutOverwritingNewestData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("old".utf8), to: file)
        var attempts = 0
        XCTAssertThrowsError(try OptimisticFileUpdate.update(at: file, lockName: "cache", maxBytes: 100) { _ in
            attempts += 1
            try FileTransaction.withLock(directory: root, name: "cache") { _ in
                try PrivateFile.write(Data("competing-\(attempts)".utf8), to: file)
            }
            return (Data("must-not-win".utf8), ())
        }) { XCTAssertEqual($0 as? StoreError, .conflict) }
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThanOrEqual(attempts, 16)
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("competing-\(attempts)".utf8))
    }

    func testCancellationDuringValidationPreservesOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("last-good".utf8), to: file)
        let cancelled = await Task {
            do {
                _ = try OptimisticFileUpdate.update(at: file, lockName: "cache", maxBytes: 100) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (Data("cancelled".utf8), ())
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("last-good".utf8))
    }

    func testValidationFailureDoesNotReplaceOrLockLastGoodBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("last-good".utf8), to: file)
        XCTAssertThrowsError(try OptimisticFileUpdate.update(at: file, lockName: "cache", maxBytes: 100) { _ -> (Data, Void) in
            throw StoreError.invalidFile
        })
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("last-good".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.lock").path))
    }

    func testBackgroundExpirationAfterStagingPreservesLastGoodAndRemovesOnlyTemporaryBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        try PrivateFile.write(Data("last-good".utf8), to: file)
        let protection = FileTransactionProtection()
        let transaction = try FileTransaction(directory: root, name: "cache", protection: protection)
        defer { withExtendedLifetime(transaction) {} }
        var interruptedStagedWrite = false
        XCTAssertThrowsError(try PrivateFile.write(Data(repeating: 7, count: 100_000), to: file) {
            let pending = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent.hasPrefix(".pending-") }
            if try pending.contains(where: { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0 }) {
                interruptedStagedWrite = true
                protection.expire()
            }
            try transaction.checkCancellation()
        }) { XCTAssertEqual($0 as? StoreError, .unavailable) }
        XCTAssertTrue(interruptedStagedWrite)
        XCTAssertEqual(try PrivateFile.read(file, maxBytes: 100), Data("last-good".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(names), ["cached.json", "cache.lock"], "Abort only this operation's staged temporary file")
    }
}
