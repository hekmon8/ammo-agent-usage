import Foundation
import QuotaCore
import Darwin

public enum StoreError: Error, Equatable { case io(Int32), invalidFile, database, conflict, unavailable, alreadyRunning }

public enum PrivateFile {
    public static func prepareDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.invalidFile }
    }
    public static func read(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { throw StoreError.unavailable }; throw StoreError.io(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maxBytes else { throw StoreError.invalidFile }
        var data = Data(count: Int(info.st_size))
        let count = data.count
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StoreError.invalidFile }
                offset += n
            }
        }
        return data
    }
    public static func write(_ data: Data, to url: URL, checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        try prepareDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io(errno) }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                try checkCancellation()
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StoreError.io(errno) }
                offset += n
            }
        }
        try checkCancellation()
        guard fsync(fd) == 0 else { throw StoreError.io(errno) }
        try checkCancellation()
        guard rename(temporary.path, url.path) == 0 else { throw StoreError.io(errno) }
        // Once committed, finish the directory flush even if execution expires.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw StoreError.io(errno) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw StoreError.io(errno) }
    }
}

public struct AtomicSnapshotReader: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func latest() throws -> Snapshot? {
        do { return try SnapshotCodec.decode(PrivateFile.read(directory.appendingPathComponent("latest-public.json"), maxBytes: SnapshotCodec.maxBytes)) }
        catch StoreError.unavailable { return nil }
    }
}

/// Lifetime lock owned only by the Mac collector. Readers never acquire it or spawn collectors.
public final class CollectorLease: @unchecked Sendable {
    private let fd: Int32
    public init(directory: URL) throws {
        try PrivateFile.prepareDirectory(directory)
        fd = open(directory.appendingPathComponent("collector.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StoreError.alreadyRunning }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

/// Short process-shared critical sections for App/Widget read-compare-replace operations.
public final class FileTransaction {
    private var fd: Int32
    private let protection: FileTransactionProtection
    private static let provider = FileTransactionProtectionProvider()

    /// The iOS app host installs a background-execution assertion provider at
    /// launch. Shared stores and WidgetKit extensions do not import UIApplication.
    public static func installProtectionProvider(_ begin: @escaping @Sendable () throws -> FileTransactionProtection) {
        provider.install(begin)
    }

    public convenience init(directory: URL, name: String) throws {
        try Task.checkCancellation()
        try self.init(directory: directory, name: name, protection: Self.provider.begin())
    }

    init(directory: URL, name: String, protection: FileTransactionProtection) throws {
        var descriptor: Int32 = -1
        var ownsProtection = false
        do {
            try Task.checkCancellation()
            try protection.beginTransaction()
            ownsProtection = true
            guard name.range(of: "^[a-z-]+$", options: .regularExpression) != nil else { throw StoreError.invalidFile }
            try PrivateFile.prepareDirectory(directory)
            descriptor = open(directory.appendingPathComponent(name + ".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StoreError.io(errno) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.invalidFile }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                try Task.checkCancellation()
                try protection.check()
                guard lockError == EWOULDBLOCK || lockError == EINTR, ProcessInfo.processInfo.systemUptime < deadline else { throw StoreError.unavailable }
                usleep(5_000)
            }
            try Task.checkCancellation()
            try protection.check()
            self.fd = descriptor
            self.protection = protection
        } catch {
            if descriptor >= 0 { close(descriptor) }
            if ownsProtection { protection.finish() }
            else { protection.finishIfUnclaimed() }
            throw error
        }
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
        try protection.checkMutation()
    }

    /// Keep the body synchronous and independent of MainActor: expiration can
    /// drain this short operation on the main thread before ending execution time.
    public static func withLock<Result>(directory: URL, name: String, _ body: (FileTransaction) throws -> Result) throws -> Result {
        let transaction = try FileTransaction(directory: directory, name: name)
        defer { transaction.release() }
        return try body(transaction)
    }

    private func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        // Ending execution protection before unlocking recreates 0xdead10cc.
        protection.finish()
    }
    deinit { release() }
}
