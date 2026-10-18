import Foundation
import CryptoKit
import Darwin

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public struct RPCQuotaResult: Sendable {
    public let limits: Data
    public let identityFingerprint: String
}

public enum BoundedRPC {
    private enum Mode: Sendable {
        case read
        case login(@Sendable (URL) -> Void)
    }

    /// Reads the currently authenticated account through a bounded app-server session.
    /// Supplying an environment replaces the ambient process environment; only the launcher
    /// allowlist is inherited by the child.
    public static func read(executable: URL, arguments: [String], timeout: TimeInterval,
                            environment: [String: String]? = nil) async throws -> RPCQuotaResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try run(executable: executable, arguments: arguments, timeout: timeout,
                        environment: environment, mode: .read, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Starts the official ChatGPT login through the app-server protocol. The callback receives
    /// only a validated HTTPS authorization URL; credential material never crosses this boundary.
    public static func login(executable: URL, arguments: [String], environment: [String: String],
                             timeout: TimeInterval = 300,
                             onAuthorizationURL: @escaping @Sendable (URL) -> Void) async throws -> RPCQuotaResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try run(executable: executable, arguments: arguments, timeout: timeout,
                        environment: environment, mode: .login(onAuthorizationURL), cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                            environment requestedEnvironment: [String: String]?, mode: Mode,
                            cancellation: CancellationFlag) throws -> RPCQuotaResult {
        let maximumTimeout: TimeInterval = switch mode { case .read: 60; case .login: 300 }
        guard executable.isFileURL, executable.path.hasPrefix("/"), timeout > 0, timeout <= maximumTimeout else { throw ProviderFailure.permissionDenied }
        if cancellation.cancelled { throw ProviderFailure.cancelled }
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw ProviderFailure.network }
        defer { close(input[0]); close(input[1]) }
        guard pipe(&output) == 0 else { throw ProviderFailure.network }
        defer { close(output[0]); close(output[1]) }
        guard pipe(&errors) == 0 else { throw ProviderFailure.network }
        defer { close(errors[0]); close(errors[1]) }
        for fd in input + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProviderFailure.permissionDenied }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0 else { throw ProviderFailure.permissionDenied }
        guard posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0 else { throw ProviderFailure.permissionDenied }
        guard posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0 else { throw ProviderFailure.permissionDenied }
        for fd in input + output + errors { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw ProviderFailure.permissionDenied } }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProviderFailure.permissionDenied }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw ProviderFailure.permissionDenied }
        let args = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = requestedEnvironment ?? ProcessInfo.processInfo.environment
        let env = ["PATH", "HOME", "TMPDIR", "LANG", "CODEX_HOME"].compactMap { key in environment[key].map { strdup("\(key)=\($0)") } } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard spawned == 0 else { throw ProviderFailure.permissionDenied }
        close(input[0]); input[0] = -1
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        defer {
            close(input[1]); input[1] = -1
            // Dedicated process group created atomically by posix_spawn, not a racy post-spawn setpgid.
            kill(-pid, SIGTERM)
            usleep(50_000)
            kill(-pid, SIGKILL)
            var result: Int32 = 0
            while waitpid(pid, &result, 0) < 0 && errno == EINTR {}
        }
        func send(_ value: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(input[1], raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ProviderFailure.network }; offset += n
                }
            }
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "ammo", "title": "Ammo", "version": "0.1.0"]]])
        var pending = Data(), total = 0, stderrBytes = 0, initialized = false
        var accountIdentity: String?
        var authenticatedAccountRead = false
        var loginID: String?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation.cancelled { throw ProviderFailure.cancelled }
            var descriptors = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0), pollfd(fd: errors[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, 2, 25)
            var stdoutClosed = false
            for index in 0..<2 {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(descriptors[index].fd, &chunk, chunk.count)
                if n == 0 && index == 0 { stdoutClosed = true }
                if n > 0 {
                    if index == 1 { stderrBytes += n; guard stderrBytes <= 32_768 else { throw ProviderFailure.outputLimit }; continue }
                    total += n; guard total <= 1_048_576 else { throw ProviderFailure.outputLimit }
                    pending.append(contentsOf: chunk.prefix(n))
                }
            }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard line.count <= 262_144 else { throw ProviderFailure.outputLimit }
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ProviderFailure.parseChanged }
                if response["method"] as? String == "account/login/completed", case .login = mode {
                    guard let params = response["params"] as? [String: Any],
                          let receivedLoginID = params["loginId"] as? String,
                          receivedLoginID == loginID,
                          let success = params["success"] as? Bool
                    else { throw ProviderFailure.parseChanged }
                    guard success else { throw ProviderFailure.authRequired }
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    continue
                }
                guard let id = response["id"] as? Int else { continue }
                if response["error"] != nil {
                    // Do not expose upstream message bodies (may contain account identifiers).
                    let code = (response["error"] as? [String: Any])?["code"] as? Int
                    if code == 401 || code == -32001 { throw ProviderFailure.authRequired }
                    throw ProviderFailure.unsupported
                }
                if id == 0 && !initialized {
                    initialized = true
                    try send(["method": "initialized"])
                    switch mode {
                    case .read:
                        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    case .login:
                        try send(["id": 3, "method": "account/login/start", "params": ["type": "chatgpt"]])
                    }
                } else if id == 3, case let .login(onAuthorizationURL) = mode {
                    guard let result = response["result"] as? [String: Any],
                          let rawURL = result["authUrl"] as? String,
                          let url = URL(string: rawURL),
                          url.scheme?.lowercased() == "https",
                          url.host != nil,
                          url.user == nil,
                          url.password == nil,
                          let receivedLoginID = result["loginId"] as? String,
                          !receivedLoginID.isEmpty
                    else { throw ProviderFailure.parseChanged }
                    loginID = receivedLoginID
                    onAuthorizationURL(url)
                } else if id == 2 && initialized {
                    guard let result = response["result"] as? [String: Any], let account = result["account"] as? [String: Any],
                          account["type"] as? String == "chatgpt" else { throw ProviderFailure.authRequired }
                    authenticatedAccountRead = true
                    if let email = account["email"] as? String, !email.isEmpty { accountIdentity = "chatgpt:" + email.lowercased() }
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 && initialized && authenticatedAccountRead, let result = response["result"] as? [String: Any] {
                    let identity: String
                    // Preserve existing email-based pins; nullable email accounts use the stable ID.
                    if let accountIdentity { identity = accountIdentity + "\n" + (result["accountId"] as? String ?? "unspecified") }
                    else if let id = result["accountId"] as? String, !id.isEmpty { identity = "chatgpt-account:" + id }
                    else { throw ProviderFailure.authRequired }
                    return RPCQuotaResult(limits: try JSONSerialization.data(withJSONObject: result), identityFingerprint: SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined())
                }
            }
            if stdoutClosed { throw ProviderFailure.parseChanged }
            guard pending.count <= 262_144 else { throw ProviderFailure.outputLimit }
        }
        throw ProviderFailure.timeout
    }
}
