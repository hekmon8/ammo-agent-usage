import Darwin
import Foundation

public enum GitHubCLIFailure: Error, Equatable, Sendable {
    case notInstalled, unsafeExecutable, notLoggedIn, billingUnavailable, billingDenied
}

private final class GitHubCLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Only the supported gh command owns/reads its login. No token command,
/// credential file, shell, interactive login or permission refresh is used.
enum GitHubCLIProcess {
    struct Result: Sendable { let output: Data; let exitCode: Int32 }
    static let locations = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    static func executable() throws -> URL {
        var found = false
        for path in locations {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            found = true
            if let binary = verifiedBinary(at: URL(fileURLWithPath: path)) { return binary }
        }
        throw found ? GitHubCLIFailure.unsafeExecutable : GitHubCLIFailure.notInstalled
    }

    static func verifiedBinary(at location: URL) -> URL? {
        guard locations.contains(location.standardizedFileURL.path) else { return nil }
        guard let binary = canonical(location) else { return nil }
        guard secureLocation(location), secureDirectoryChain(binary.deletingLastPathComponent()) else { return nil }
        var info = stat()
        guard binary.isFileURL, stat(binary.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0,
              FileManager.default.isExecutableFile(atPath: binary.path),
              CodexAppDiscovery.isNativeMachO(binary) else { return nil }
        return binary
    }

    /// Homebrew may grant its admin group write access. Root/current user and
    /// macOS wheel/admin are already privileged code owners; other writers fail.
    static func canonical(_ location: URL) -> URL? {
        guard let path = realpath(location.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func secureDirectoryChain(_ location: URL) -> Bool {
        guard var directory = canonical(location) else { return false }
        while true {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() || info.st_uid == 0,
                  info.st_mode & 0o002 == 0 || info.st_mode & 0o1000 != 0,
                  info.st_mode & 0o020 == 0 || info.st_gid == 0 || info.st_gid == 80 || info.st_mode & 0o1000 != 0,
                  !hasWriteACL(directory) else { return false }
            if directory.path == "/" { return true }
            directory.deleteLastPathComponent()
        }
    }

    static func secureLocation(_ location: URL) -> Bool {
        let normalized = location.standardized
        guard secureDirectoryChain(normalized.deletingLastPathComponent()) else { return false }
        var info = stat()
        guard lstat(normalized.path, &info) == 0 else { return false }
        var target = normalized
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: normalized.path) else { return false }
            target = (link.hasPrefix("/") ? URL(fileURLWithPath: link) : normalized.deletingLastPathComponent().appendingPathComponent(link)).standardized
            guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        // Reject additional directory/file symlink hops, even in a writable shim.
        guard target.path == canonical(target)?.path else { return false }
        return secureDirectoryChain(target.deletingLastPathComponent()) && !hasWriteACL(target)
    }

    private static func hasWriteACL(_ location: URL) -> Bool {
        guard let acl = acl_get_file(location.path, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT && errno != ENOTSUP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY
        let writes = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
                      ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
            .reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        while acl_get_entry(acl, Int32(entryID.rawValue), &entry) == 0 {
            entryID = ACL_NEXT_ENTRY
            var tag = acl_tag_t(rawValue: 0)
            var set: acl_permset_t?
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &set) == 0,
                  acl_get_permset_mask_np(set, &mask) == 0 else { return true }
            if tag == ACL_EXTENDED_ALLOW && UInt64(mask) & writes != 0 { return true }
        }
        return false
    }

    /// GUI PATH is not a discovery input. Inherited token/host/debug/askpass
    /// variables are intentionally absent; gh uses its own existing login.
    static func environment(home: String, inherited: [String: String]) -> [String: String] {
        var env = ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                   "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                   "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"]
        for key in ["TMPDIR", "LANG", "LC_ALL"] { env[key] = inherited[key] }
        // This is an existing CLI config location, not a credential value.
        for key in ["GH_CONFIG_DIR", "XDG_CONFIG_HOME"] {
            if let path = inherited[key], path.hasPrefix("/"), !path.contains("\0") { env[key] = path }
        }
        return env
    }

    static func run(binary: URL, arguments: [String], timeout: TimeInterval = 15,
                    verifyExecutableBeforeSpawn: Bool = false,
                    maxBytes: Int = 2_162_688) async throws -> Result {
        let cancellation = GitHubCLICancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try waitOut(binary: binary, arguments: arguments, timeout: timeout,
                            verifyExecutable: verifyExecutableBeforeSpawn, maxBytes: maxBytes, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func waitOut(binary: URL, arguments: [String], timeout: TimeInterval,
                                verifyExecutable: Bool,
                                maxBytes: Int, cancellation: GitHubCLICancellation) throws -> Result {
        guard binary.isFileURL, binary.path.hasPrefix("/"), timeout > 0, timeout <= 30,
              maxBytes > 0, maxBytes <= 2_162_688 else { throw ProviderFailure.permissionDenied }
        if cancellation.cancelled { throw ProviderFailure.cancelled }
        var checked = stat()
        let codeFD = verifyExecutable ? Darwin.open(binary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) : -1
        defer { if codeFD >= 0 { close(codeFD) } }
        if verifyExecutable {
            guard codeFD >= 0, fstat(codeFD, &checked) == 0, secureLocation(binary),
                  checked.st_mode & S_IFMT == S_IFREG, checked.st_mode & 0o022 == 0,
                  checked.st_uid == getuid() || checked.st_uid == 0 else { throw GitHubCLIFailure.unsafeExecutable }
        }
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        defer { for fd in output + errors where fd >= 0 { close(fd) } }
        guard pipe(&output) == 0, pipe(&errors) == 0 else { throw ProviderFailure.network }
        let nullFD = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullFD >= 0 else { throw ProviderFailure.network }
        defer { close(nullFD) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProviderFailure.network }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0 else {
            throw ProviderFailure.network
        }
        for fd in output + errors + [nullFD] { posix_spawn_file_actions_addclose(&actions, fd) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProviderFailure.network }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw ProviderFailure.network }
        let args = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let env = environment(home: FileManager.default.homeDirectoryForCurrentUser.path,
                              inherited: ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        if verifyExecutable {
            var current = stat()
            guard secureLocation(binary), lstat(binary.path, &current) == 0,
                  current.st_dev == checked.st_dev, current.st_ino == checked.st_ino,
                  current.st_uid == checked.st_uid, current.st_mode == checked.st_mode else {
                throw GitHubCLIFailure.unsafeExecutable
            }
        }
        let spawned = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, binary.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard spawned == 0 else { throw ProviderFailure.permissionDenied }
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        var reaped = false
        defer {
            if !reaped {
                // Only the group created atomically for our child is stopped.
                kill(-pid, SIGTERM); usleep(50_000); kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        for fd in [output[0], errors[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var body = Data(), total = 0, exitCode: Int32 = -1
        var eof = Set<Int32>()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation.cancelled { throw ProviderFailure.cancelled }
            var fds = [output[0], errors[0]].map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            _ = poll(&fds, 2, 25)
            for fd in [output[0], errors[0]] where !eof.contains(fd) {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    total += count
                    guard total <= maxBytes else { throw ProviderFailure.outputLimit }
                    if fd == output[0] { body.append(contentsOf: chunk.prefix(count)) }
                    // stderr is bounded and discarded, never displayed/logged.
                } else if count == 0 { eof.insert(fd) }
                else if errno != EAGAIN && errno != EINTR { throw ProviderFailure.network }
            }
            // Keep an exited leader unreaped while descendants hold pipes, so
            // its PID/group cannot be reused before timeout/cancel cleanup.
            if !reaped && eof.count == 2 {
                var observation = siginfo_t()
                guard waitid(P_PID, id_t(pid), &observation, WEXITED | WNOWAIT | WNOHANG) == 0 else {
                    if errno == EINTR { continue }; throw ProviderFailure.network
                }
                guard observation.si_pid == pid else { continue }
                // Leader stays reserved as a zombie until all remaining group
                // members are stopped, including descendants with closed pipes.
                kill(-pid, SIGTERM); usleep(50_000); kill(-pid, SIGKILL)
                var status: Int32 = 0
                let waited = waitpid(pid, &status, 0)
                if waited == pid {
                    reaped = true
                    guard status & 0x7f == 0 else { throw ProviderFailure.network }
                    exitCode = (status >> 8) & 0xff
                } else if waited < 0 && errno != EINTR { throw ProviderFailure.network }
            }
            if reaped && eof.count == 2 { return Result(output: body, exitCode: exitCode) }
        }
        throw ProviderFailure.timeout
    }
}
