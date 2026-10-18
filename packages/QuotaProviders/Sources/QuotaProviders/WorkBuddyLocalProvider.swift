import Foundation
import QuotaCore

/// Read-only access to this Mac's existing WorkBuddy desktop login. Each fetch
/// re-reads the session file the desktop app itself maintains
/// (`~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/
/// workbuddy-desktop.info`), so tokens the app renews are picked up
/// automatically. The token is never refreshed here: the refresh grant belongs
/// to the desktop app, so an expired entry waits for its next run. The billing
/// endpoint is pinned to the SaaS host; the file's own `auth.domain` is never
/// followed, so a tampered file cannot redirect the token elsewhere.
public struct WorkBuddyLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "workbuddy", displayName: "WorkBuddy", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    static var sessionFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
    }

    struct StoredSession {
        let accessToken: String
        let userID: String?
    }

    private struct StoredFile: Decodable {
        struct Auth: Decodable { let accessToken: String?; let expiresAt: Double? }
        struct Account: Decodable { let uid: String? }
        let auth: Auth?
        let account: Account?
    }

    /// `expiresAt` is epoch milliseconds; a 30 s margin covers clock skew.
    static func readSession(from data: Data, now: Date) throws -> StoredSession {
        guard data.count <= 65_536,
              let stored = try? JSONDecoder().decode(StoredFile.self, from: data),
              let token = stored.auth?.accessToken, token.count >= 8, !token.contains(where: \.isWhitespace) else {
            throw ProviderFailure.authRequired
        }
        if let expiresAt = stored.auth?.expiresAt,
           Date(timeIntervalSince1970: expiresAt / 1000) <= now.addingTimeInterval(30) {
            throw ProviderFailure.authRequired
        }
        return StoredSession(accessToken: token, userID: stored.account?.uid)
    }

    /// The desktop app writes this file mode 0644, so unlike the CLI-credential
    /// channels only the regular-file, ownership and size bounds apply.
    static func readSessionFile() throws -> Data {
        let descriptor = Darwin.open(sessionFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ENOENT ? ProviderFailure.authRequired : ProviderFailure.permissionDenied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 65_536 else {
            throw ProviderFailure.permissionDenied
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw ProviderFailure.outputLimit }
        return data
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil)
    }

    public func fetch(now: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity, now: now)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    static func read(alias: String, expectedIdentity: String?, now: Date = Date()) async throws -> NativeProviderProbeResult {
        try Task.checkCancellation()
        let session = try readSession(from: readSessionFile(), now: now)
        let usage: NativeUsage
        do { usage = try await WorkBuddyUsageReader.fetch(token: session.accessToken, userID: session.userID) }
        catch NativeProviderAPIError.credentialRejected { throw ProviderFailure.authRequired }
        // The billing response's shared Uin is the only self-reported account
        // identity; the file's uid is transport metadata, not proof of ownership.
        guard usage.identity.accountID != nil else { throw ProviderFailure.authRequired }
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "workbuddy", alias: alias, source: .officialAPI)
        guard expectedIdentity == nil || expectedIdentity == result.identityFingerprint else {
            throw ProviderFailure.authRequired
        }
        return NativeProviderProbeResult(accountID: result.accountID, identityFingerprint: result.identityFingerprint,
                                         windows: result.windows)
    }
}
