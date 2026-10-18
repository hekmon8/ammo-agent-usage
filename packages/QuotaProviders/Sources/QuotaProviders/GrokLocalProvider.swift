import Foundation
import QuotaCore

/// Read-only access to the machine's existing Grok CLI login
/// (`~/.grok/auth.json`). The OIDC token drives the official billing proxy,
/// and the connection identity is reproduced from the file's user/team fields
/// so upgraded connections keep their pinned fingerprint and history.
/// Expired tokens are never sent: the CLI is launched once to refresh its own
/// file, and the refreshed entry is re-read and re-pinned before any request.
public struct GrokLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "grok", displayName: "Grok", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    public static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    struct AuthEntry {
        let token: String
        let userID: String
        let teamID: String?
        let email: String?
        let expiresAt: Date?
    }

    /// The CLI stores one entry per auth scope; only the OpenAI-style OIDC
    /// scope carries the personal SuperGrok login this channel consumes.
    static func readEntry(from data: Data) throws -> AuthEntry {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.authRequired
        }
        for (scope, value) in json {
            guard scope.hasPrefix("https://auth.x.ai"), let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty else { continue }
            guard let userID = entry["user_id"] as? String, !userID.isEmpty, userID.utf8.count <= 256 else {
                throw ProviderFailure.authRequired
            }
            let teamID = (entry["team_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let email = (entry["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let expiresAt = (entry["expires_at"] as? String).flatMap(NativeAPIParsing.date)
            return AuthEntry(token: token, userID: userID, teamID: teamID, email: email, expiresAt: expiresAt)
        }
        throw ProviderFailure.authRequired
    }

    /// x.ai issues short-lived access tokens (~6 h). A small margin covers
    /// clock skew; entries without any readable deadline are sent as-is so a
    /// parse change can never silently disable the channel — the billing proxy
    /// still rejects stale tokens.
    static func isExpired(_ entry: AuthEntry, now: Date) -> Bool {
        guard let expiry = entry.expiresAt ?? jwtExpiration(entry.token) else { return false }
        return expiry <= now.addingTimeInterval(30)
    }

    /// Older auth files may omit `expires_at`; the access token is an `at+jwt`
    /// whose `exp` claim carries the same deadline.
    private static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[1].utf8.count <= 32_768 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "/", with: "_")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    static func readCredentials(from url: URL) throws -> AuthEntry {
        try readEntry(from: readPrivateFile(url))
    }

    /// Owner-only regular file, no symlink, at most 64 KiB.
    static func readPrivateFile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ENOENT ? ProviderFailure.authRequired : ProviderFailure.permissionDenied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw ProviderFailure.permissionDenied }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw ProviderFailure.outputLimit }
        return data
    }

    /// The released bridge digested the CLI identity together with the team
    /// scope; reproduce byte-for-byte so upgraded connections keep their
    /// stored fingerprint.
    static func fingerprint(userID: String, teamID: String?) -> String {
        let scope = teamID.map { "\norganization=\($0)" } ?? ""
        return NativeProviderNormalizer.sha256("automatic-account-id\ngrok\n\(userID)\(scope)")
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil, authFile: authFile)
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity, authFile: Self.authFile)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    static func read(alias: String, expectedIdentity: String?, authFile: URL) async throws -> NativeProviderProbeResult {
        try Task.checkCancellation()
        var entry = try readCredentials(from: authFile)
        if Self.isExpired(entry, now: Date()) {
            // The CLI owns the credential file and the refresh-token lifecycle;
            // x.ai rotates the refresh token on every redemption, so it is
            // redeemed in the CLI's process, never here. Re-reading re-pins the
            // identity below, so an account swap during refresh fails closed.
            try await GrokNativeRefresh.launch(authFile)
            entry = try readCredentials(from: authFile)
            guard !Self.isExpired(entry, now: Date()) else { throw ProviderFailure.authRequired }
        }
        let fingerprint = fingerprint(userID: entry.userID, teamID: entry.teamID)
        guard expectedIdentity == nil || expectedIdentity == fingerprint else { throw ProviderFailure.authRequired }
        let accountID = "native-" + String(fingerprint.prefix(32))
        guard let token = GrokUsageReader.normalizedToken(entry.token) else { throw ProviderFailure.authRequired }
        let data: Data
        do {
            data = try await NativeHTTP.request("GET", GrokUsageReader.endpoint, headers: [
                "Authorization": "Bearer " + token,
                "x-xai-token-auth": "xai-grok-cli",
                "User-Agent": "Ammo/1",
            ]).data
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw ProviderFailure.authRequired }
            if case .httpStatus(403) = failure { throw ProviderFailure.authRequired }
            throw failure
        }
        let usage = try GrokUsageReader.parse(
            data: data,
            identity: .init(accountID: entry.userID, email: entry.email, organization: entry.teamID))
        let windows = try NativeProviderNormalizer.normalize(usage, providerID: "grok",
                                                             alias: alias, source: .officialAPI)
        return NativeProviderProbeResult(accountID: accountID, identityFingerprint: fingerprint, windows: windows.windows)
    }
}
