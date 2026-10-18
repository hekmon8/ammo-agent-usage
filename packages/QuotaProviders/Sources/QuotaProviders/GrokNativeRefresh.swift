import Darwin
import Foundation

private final class RefreshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Delegates the OIDC refresh of `~/.grok/auth.json` to the Grok CLI itself.
/// x.ai rotates the refresh token on every redemption, so redeeming it in
/// this process without writing the file back would strand the CLI with an
/// invalidated token; launching the CLI keeps the rotation inside the process
/// that owns the credential file. `grok models` silently refreshes an expired
/// token during startup, needs no terminal, and burns no model tokens.
enum GrokNativeRefresh {
    /// The CLI's own managed launcher sits in the auth home it serves; the
    /// remaining candidates cover the installer shim and Homebrew channels.
    /// Every candidate is validated as a user-owned executable before spawn.
    static func candidateBinaries(authFile: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            authFile.deletingLastPathComponent().appendingPathComponent("bin/grok"),
            home.appendingPathComponent(".local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ]
    }

    static func verifiedBinary(at location: URL) -> URL? {
        let resolved = location.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard resolved.isFileURL,
              FileManager.default.fileExists(atPath: resolved.path),
              FileManager.default.isExecutableFile(atPath: resolved.path),
              stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() else { return nil }
        return resolved
    }

    static func launch(_ authFile: URL, timeout: TimeInterval = 20) async throws {
        guard let binary = candidateBinaries(authFile: authFile)
            .compactMap({ verifiedBinary(at: $0) }).first else {
            throw ProviderFailure.authRequired
        }
        try await run(binary: binary, timeout: timeout)
    }

    /// One bounded launch. The exit status and output are ignored on purpose:
    /// the refresh happens while the CLI starts up, and the caller decides
    /// success by re-reading `auth.json`, never by the child's answer.
    static func run(binary: URL, arguments: [String] = ["models"],
                    timeout: TimeInterval = 20) async throws {
        let cancellation = RefreshCancellation()
        try await withTaskCancellationHandler {
            try await Task.detached {
                try waitOut(binary: binary, arguments: arguments, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func waitOut(binary: URL, arguments: [String], timeout: TimeInterval,
                                cancellation: RefreshCancellation) throws {
        guard binary.isFileURL, binary.path.hasPrefix("/"), timeout > 0, timeout <= 60 else {
            throw ProviderFailure.permissionDenied
        }
        if cancellation.cancelled { throw ProviderFailure.cancelled }
        var output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&output) == 0, pipe(&errors) == 0 else { throw ProviderFailure.network }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProviderFailure.permissionDenied }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The CLI must never wait on this process: stdin is /dev/null and both
        // output pipes are drained for as long as the child runs.
        let nullFD = Darwin.open("/dev/null", O_RDONLY)
        guard nullFD >= 0 else { throw ProviderFailure.permissionDenied }
        guard posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, nullFD) == 0 else {
            close(nullFD); throw ProviderFailure.permissionDenied
        }
        for fd in output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errors[0], F_SETFL, O_NONBLOCK)
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { close(nullFD); throw ProviderFailure.permissionDenied }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(nullFD); throw ProviderFailure.permissionDenied
        }
        let args = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment
        let env = ["PATH", "HOME", "TMPDIR", "LANG"].compactMap { key in
            environment[key].map { strdup("\(key)=\($0)") }
        } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, binary.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        close(nullFD)
        guard spawned == 0 else { throw ProviderFailure.permissionDenied }
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        defer {
            // Dedicated process group created atomically by posix_spawn, not a
            // racy post-spawn setpgid.
            kill(-pid, SIGTERM)
            usleep(50_000)
            kill(-pid, SIGKILL)
            var result: Int32 = 0
            while waitpid(pid, &result, 0) < 0 && errno == EINTR {}
        }
        var total = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation.cancelled { throw ProviderFailure.cancelled }
            var descriptors = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errors[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, 2, 25)
            for descriptor in descriptors {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(descriptor.fd, &chunk, chunk.count)
                // Output is discarded; the rewritten file is the only signal.
                total += max(n, 0)
            }
            guard total <= 1_048_576 else { throw ProviderFailure.outputLimit }
            var result: Int32 = 0
            let waited = waitpid(pid, &result, WNOHANG)
            if waited == pid { return }
            guard waited == 0 || (waited < 0 && errno == EINTR) else { throw ProviderFailure.network }
        }
        throw ProviderFailure.timeout
    }
}
