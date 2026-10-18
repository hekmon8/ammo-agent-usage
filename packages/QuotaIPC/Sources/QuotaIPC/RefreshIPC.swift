import Foundation
import Darwin
import QuotaStore

public enum IPCError: Error { case unavailable, permission, timeout, invalid, failed }
private enum SocketIO {
    static func descriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.unavailable }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw IPCError.unavailable }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
    static func address(_ directory: URL) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(directory.appendingPathComponent("refresh.sock").path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError.invalid }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func authorized(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw IPCError.permission }
    }
    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            if poll(&descriptor, 1, 50) > 0 {
                if descriptor.revents & events != 0 { return }
                throw IPCError.unavailable
            }
        }
        throw IPCError.timeout
    }
    static func send(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard n > 0 else { throw IPCError.unavailable }; offset += n
            }
        }
    }
    static func line(_ fd: Int32, deadline: TimeInterval) throws -> Data {
        var result = Data()
        while result.count < 512 {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard n == 1 else { throw IPCError.unavailable }
            if byte == 10 { return result }; result.append(byte)
        }
        throw IPCError.invalid
    }
}

public enum RefreshClient {
    public static func request(directory: URL, provider: String?, timeout: TimeInterval) async throws {
        guard timeout > 0, timeout <= 60 else { throw IPCError.invalid }
        let operation = Task.detached {
            // Inspect the container without creating a collector or a database.
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw IPCError.permission }
            let fd = try SocketIO.descriptor(); defer { close(fd) }
            var address = try SocketIO.address(directory)
            let code = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            if code != 0 {
                guard errno == EINPROGRESS else { throw IPCError.unavailable }
                try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var failure: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { throw IPCError.unavailable }
            }
            try SocketIO.authorized(fd)
            var body: [String: String] = ["version": "1", "operation": "refresh"]
            if let provider { body["provider"] = provider }
            var data = try JSONSerialization.data(withJSONObject: body); data.append(10)
            try SocketIO.send(data, fd: fd, deadline: deadline)
            let reply = try SocketIO.line(fd, deadline: deadline)
            guard reply == Data("{\"ok\":true}".utf8) else { throw IPCError.failed }
        }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}

/// Owned by the same Mac lifecycle as CollectorLease. No listener is started by CLI/MCP.
public actor RefreshServer {
    private var task: Task<Void, Never>?
    public init() {}
    public func start(directory: URL, handler: @escaping @Sendable (String?) async throws -> Void) throws {
        guard task == nil else { throw IPCError.invalid }
        try PrivateFile.prepareDirectory(directory)
        let path = directory.appendingPathComponent("refresh.sock").path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw IPCError.permission }
            // Caller already owns CollectorLease, so this is an abandoned socket from that collector.
            guard unlink(path) == 0 else { throw IPCError.permission }
        }
        var address = try SocketIO.address(directory)
        let fd = try SocketIO.descriptor()
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw IPCError.unavailable }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(path); throw IPCError.unavailable
        }
        task = Task.detached {
            defer { close(fd); unlink(path) }
            while !Task.isCancelled {
                do {
                    try SocketIO.wait(fd, events: Int16(POLLIN), deadline: ProcessInfo.processInfo.systemUptime + 1)
                    let peer = accept(fd, nil, nil)
                    guard peer >= 0 else { continue }
                    defer { close(peer) }
                    guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0,
                          fcntl(peer, F_SETFL, O_NONBLOCK) == 0 else { throw IPCError.unavailable }
                    var enabled: Int32 = 1
                    _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                    try SocketIO.authorized(peer)
                    let data = try SocketIO.line(peer, deadline: ProcessInfo.processInfo.systemUptime + 1)
                    guard let input = try JSONSerialization.jsonObject(with: data) as? [String: String],
                          Set(input.keys).isSubset(of: ["version", "operation", "provider"]), input["version"] == "1", input["operation"] == "refresh",
                          input["provider"].map({ $0.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil }) ?? true else { throw IPCError.invalid }
                    var ok = true
                    do { try await handler(input["provider"]) } catch { ok = false }
                    try SocketIO.send(Data((ok ? "{\"ok\":true}\n" : "{\"ok\":false}\n").utf8), fd: peer, deadline: ProcessInfo.processInfo.systemUptime + 1)
                } catch { /* Fail closed, bounded request; no input or identifiers enter logs. */ }
            }
        }
    }
    public func stop() async { task?.cancel(); await task?.value; task = nil }
}
