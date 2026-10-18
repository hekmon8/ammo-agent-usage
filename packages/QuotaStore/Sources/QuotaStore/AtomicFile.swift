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
    public static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io(errno) }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StoreError.io(errno) }
                offset += n
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw StoreError.io(errno) }
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
    private let fd: Int32
    public init(directory: URL, name: String) throws {
        guard name.range(of: "^[a-z-]+$", options: .regularExpression) != nil else { throw StoreError.invalidFile }
        try PrivateFile.prepareDirectory(directory)
        fd = open(directory.appendingPathComponent(name + ".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw StoreError.invalidFile }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ProcessInfo.processInfo.systemUptime < deadline else { close(fd); throw StoreError.unavailable }
            usleep(5_000)
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
