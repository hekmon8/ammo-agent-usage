import Darwin
import Foundation
import XCTest
@testable import QuotaPhone
@testable import QuotaStore

@MainActor
final class FileTransactionBackgroundAssertionTests: XCTestCase {
    @MainActor private final class SystemTask {
        var expiration: (@MainActor @Sendable () -> Void)?
        var ended: [Int] = []
        var deny = false
        var expireInline = false
        var onEnd: (() -> Void)?
        func start(_ expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
            expiration = expired
            if expireInline { expired() }
            return deny ? nil : 42
        }
        func end(_ identifier: Int) { ended.append(identifier); onEnd?() }
    }

    private func begin(_ system: SystemTask) throws -> FileTransactionProtection {
        try PhoneFileTransactionBackgroundAssertion.begin(start: { system.start($0) }, end: { system.end($0) })
    }

    private static func canTakeLock(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    func testExpirationDrainsStagedWriteAndEndsSynchronouslyAfterUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.json")
        let lockFile = root.appendingPathComponent("cache.lock")
        try PrivateFile.write(Data("last-good".utf8), to: file)
        let system = SystemTask()
        system.onEnd = {
            XCTAssertTrue(Self.canTakeLock(lockFile), "System end must see the descriptor already released")
            XCTAssertEqual(try? PrivateFile.read(file, maxBytes: 100), Data("last-good".utf8))
            XCTAssertFalse((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.contains(where: { $0.hasPrefix(".pending-") }) ?? true)
        }
        let protection = try begin(system)
        let staged = AsyncStream<Void>.makeStream()
        let work = Task.detached {
            defer { staged.continuation.finish() }
            do {
                let transaction = try FileTransaction(directory: root, name: "cache", protection: protection)
                defer { withExtendedLifetime(transaction) {} }
                try PrivateFile.write(Data(repeating: 7, count: 100_000), to: file) {
                    let pending = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
                        .filter { $0.lastPathComponent.hasPrefix(".pending-") }
                    if try pending.contains(where: { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0 }) {
                        staged.continuation.yield()
                        let deadline = Date().addingTimeInterval(3)
                        while !protection.isExpired && Date() < deadline { usleep(1_000) }
                    }
                    try transaction.checkCancellation()
                }
                return false
            } catch StoreError.unavailable { return true }
            catch { return false }
        }
        var iterator = staged.stream.makeAsyncIterator()
        let stageReached = await iterator.next()
        XCTAssertNotNil(stageReached)
        system.expiration?()
        XCTAssertEqual(system.ended, [42], "Cleanup must finish before the expiration callback returns, without a MainActor hop")
        let interrupted = await work.value
        XCTAssertTrue(interrupted)
        await Task.yield()
        XCTAssertEqual(system.ended, [42])
    }

    func testExpirationDuringContentionClosesWaiterWithoutUnlockingOtherOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try FileTransaction(directory: root, name: "cache")
        defer { withExtendedLifetime(other) {} }
        let lockFile = root.appendingPathComponent("cache.lock")
        let system = SystemTask()
        system.onEnd = { XCTAssertFalse(Self.canTakeLock(lockFile), "Expiration must not release another transaction's lock") }
        let protection = try begin(system)
        let started = AsyncStream<Void>.makeStream()
        let work = Task.detached {
            defer { started.continuation.finish() }
            started.continuation.yield()
            do { _ = try FileTransaction(directory: root, name: "cache", protection: protection); return false }
            catch StoreError.unavailable { return true }
            catch { return false }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let deadline = Date().addingTimeInterval(3)
        while !protection.isTransactionActive && Date() < deadline { await Task.yield() }
        XCTAssertTrue(protection.isTransactionActive, "Expire an admitted waiter, not a task that has not started")
        system.expiration?()
        XCTAssertEqual(system.ended, [42])
        let interrupted = await work.value
        XCTAssertTrue(interrupted)
        await Task.yield()
        XCTAssertEqual(system.ended, [42])
    }

    func testExpirationBeforeAdmissionAndInlineExpirationNeverAllowLock() async throws {
        for inline in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let system = SystemTask(); system.expireInline = inline
            if inline {
                XCTAssertThrowsError(try begin(system))
            } else {
                let protection = try begin(system)
                system.expiration?()
                XCTAssertThrowsError(try FileTransaction(directory: root, name: "cache", protection: protection))
            }
            XCTAssertEqual(system.ended, [42])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            await Task.yield()
            XCTAssertEqual(system.ended, [42])
        }
    }

    func testDeniedSystemAssertionDoesNotEndAnInvalidIdentifier() async {
        let system = SystemTask(); system.deny = true
        XCTAssertThrowsError(try begin(system))
        await Task.yield()
        XCTAssertTrue(system.ended.isEmpty)
    }
}
