import Foundation
import Darwin

/// An app-owned Codex profile. Its separate HOME and CODEX_HOME prevent a connection
/// from reading or modifying the user's ambient Codex login.
public struct CodexInstanceProfile: Sendable, Equatable {
    public let id: UUID
    public let root: URL
    public let directory: URL
    public let home: URL
    public let codexHome: URL
    public let temporaryDirectory: URL
    public let authFile: URL

    /// These arguments force the CLI credential backend to its profile-local file before
    /// app-server starts. Callers must pass `environment()` to the same child process.
    public static let appServerArguments = [
        "-s", "read-only",
        "-a", "never",
        "-c", "cli_auth_credentials_store=\"file\"",
        "app-server",
    ]

    /// Describes exactly one UUID-named profile beneath an app-owned root. Construction never
    /// creates directories, so loading a deleted record cannot recreate credentials on cleanup.
    public init(root: URL, id: UUID = UUID()) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw ProviderFailure.permissionDenied }
        self.id = id
        self.root = root.standardizedFileURL
        self.directory = self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        self.home = directory.appendingPathComponent("home", isDirectory: true)
        self.codexHome = directory.appendingPathComponent("codex", isDirectory: true)
        self.temporaryDirectory = directory.appendingPathComponent("tmp", isDirectory: true)
        self.authFile = codexHome.appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Restores a persisted UUID without accepting arbitrary path components.
    public init(root: URL, id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw ProviderFailure.permissionDenied }
        try self.init(root: root, id: uuid)
    }

    /// Creates the private profile directories. Login flows must call this explicitly before
    /// launching Codex; recurring fetches use `validate()` and never recreate a deleted profile.
    public func prepare() throws {
        try Self.ensureRootDirectory(root)
        try Self.ensurePrivateDirectory(directory)
        try Self.ensurePrivateDirectory(home)
        try Self.ensurePrivateDirectory(codexHome)
        try Self.ensurePrivateDirectory(temporaryDirectory)
        try validate()
    }

    /// Returns a narrow child environment. It never forwards the caller's ambient HOME,
    /// CODEX_HOME, credential variables, or arbitrary configuration.
    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        try validate()
        return [
            "PATH": base["PATH"] ?? "/usr/bin:/bin",
            "LANG": base["LANG"] ?? "en_US.UTF-8",
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "TMPDIR": temporaryDirectory.path + "/",
        ]
    }

    /// Checks the profile before it is used or removed so a persisted path cannot escape its
    /// UUID root through a symlink or an unexpectedly permissive directory.
    public func validate() throws {
        guard directory.lastPathComponent == id.uuidString,
              directory.deletingLastPathComponent().standardizedFileURL == root
        else { throw ProviderFailure.permissionDenied }
        try Self.validatePrivateDirectory(root)
        for path in [directory, home, codexHome, temporaryDirectory] {
            try Self.validatePrivateDirectory(path)
        }
        if try Self.status(authFile) != nil { try Self.validatePrivateRegularFile(authFile) }
    }

    /// Removes only this validated UUID profile. Callers must first stop any child process using it.
    public func remove() throws {
        guard try Self.status(root) != nil else { return }
        try Self.validatePrivateDirectory(root)
        guard try Self.status(directory) != nil else { return }
        // A failed login may leave only a subset of the profile directories. Validate the
        // UUID-owned root itself, then remove that root; do not recreate missing children.
        try Self.validatePrivateDirectory(directory)
        try FileManager.default.removeItem(at: directory)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try validatePrivateDirectory(url)
            return
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try validatePrivateDirectory(url)
    }

    private static func ensureRootDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try validatePrivateDirectory(url)
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        guard let info = try status(url),
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0
        else { throw ProviderFailure.permissionDenied }
    }

    private static func validatePrivateRegularFile(_ url: URL) throws {
        guard let info = try status(url),
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0
        else { throw ProviderFailure.permissionDenied }
    }

    /// `lstat` deliberately examines a link itself rather than resolving its destination.
    private static func status(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw ProviderFailure.permissionDenied
    }
}
