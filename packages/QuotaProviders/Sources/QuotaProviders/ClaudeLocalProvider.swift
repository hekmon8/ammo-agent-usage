import Foundation
import QuotaCore

/// Read-only access to this Mac's existing Claude Code login. Each fetch
/// re-reads the stored OAuth entry — `~/.claude/.credentials.json` when
/// present, otherwise the `Claude Code-credentials` Keychain item through
/// `/usr/bin/security`, the tool Claude Code itself writes it with — so tokens
/// Claude Code refreshes are picked up automatically. The token is never
/// refreshed here: Anthropic rotates the refresh token on redemption, which
/// would sign Claude Code out. An expired entry waits for Claude Code's next run.
public struct ClaudeLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "claude", displayName: "Claude", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private struct Stored: Decodable {
        struct OAuth: Decodable { let accessToken: String?; let expiresAt: Double? }
        let claudeAiOauth: OAuth?
    }

    /// `expiresAt` is epoch milliseconds; a 30 s margin covers clock skew.
    static func accessToken(from data: Data, now: Date) throws -> String {
        guard let oauth = (try? JSONDecoder().decode(Stored.self, from: data))?.claudeAiOauth,
              let raw = oauth.accessToken, let token = ClaudeUsageReader.accessToken(from: raw) else {
            throw ProviderFailure.authRequired
        }
        if let expiresAt = oauth.expiresAt,
           Date(timeIntervalSince1970: expiresAt / 1000) <= now.addingTimeInterval(30) {
            throw ProviderFailure.authRequired
        }
        return token
    }

    /// The file may exist holding only MCP server logins (`mcpOAuth`) while the
    /// account token lives in the Keychain, so the file wins only with a usable token.
    static func storedAccessToken(now: Date) async throws -> String {
        if FileManager.default.fileExists(atPath: credentialsFile.path),
           let token = try? accessToken(from: GrokLocalProvider.readPrivateFile(credentialsFile), now: now) {
            return token
        }
        return try accessToken(from: await Task.detached(priority: .utility) { try readKeychain() }.value, now: now)
    }

    private static func readKeychain() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ProviderFailure.permissionDenied }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        // Exit 44 = no such item: Claude Code has never signed in on this Mac.
        guard process.terminationStatus == 0 else { throw ProviderFailure.authRequired }
        guard data.count <= 65_536 else { throw ProviderFailure.outputLimit }
        return data
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil)
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    static func read(alias: String, expectedIdentity: String?) async throws -> NativeProviderProbeResult {
        try Task.checkCancellation()
        let token = try await storedAccessToken(now: Date())
        let usage: NativeUsage
        do { usage = try await ClaudeUsageReader.fetch(token: token) }
        catch NativeProviderAPIError.credentialRejected { throw ProviderFailure.authRequired }
        // Tokens rotate, so only the self-reported account can pin this login.
        guard usage.identity.accountID != nil else { throw ProviderFailure.authRequired }
        let result = try NativeProviderNormalizer.normalize(usage, providerID: "claude", alias: alias, source: .officialAPI)
        guard expectedIdentity == nil || expectedIdentity == result.identityFingerprint else {
            throw ProviderFailure.authRequired
        }
        return NativeProviderProbeResult(accountID: result.accountID, identityFingerprint: result.identityFingerprint,
                                         windows: result.windows)
    }
}
