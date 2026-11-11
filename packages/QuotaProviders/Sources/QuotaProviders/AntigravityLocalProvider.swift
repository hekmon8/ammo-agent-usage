import Darwin
import Foundation
import QuotaCore

/// The installed agy owns sign-in and renewal. Ammo reads its usage report and
/// verifies the Google account; it never saves or redeems the refresh token.
public struct AntigravityLocalProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "antigravity", displayName: "Antigravity", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    public init(accountID: String, alias: String, expectedIdentity: String) {
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    public static func probe(alias: String) async throws -> NativeProviderProbeResult {
        try await read(alias: alias, expectedIdentity: nil)
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        let result = try await Self.read(alias: alias, expectedIdentity: credentialIdentity)
        guard result.accountID == accountID else { throw ProviderFailure.authRequired }
        return result.windows
    }

    static func read(alias: String, expectedIdentity: String?,
                     token: () async throws -> String = storedAccessToken,
                     report: () async throws -> Data = usageReport,
                     identity: (String) async throws -> String = googleSubject) async throws -> NativeProviderProbeResult {
        do {
            // A report carries no account ID. Never label it using a token from
            // a different login. If agy renewed the token, discard that report
            // and retry once with the new token before verifying its subject.
            for _ in 0..<2 {
                try Task.checkCancellation()
                let before = try await token()
                let data = try await report()
                let after = try await token()
                guard before == after else { continue }
                let subject = try await identity(after)
                guard !subject.isEmpty, subject.utf8.count <= 512 else { throw ProviderFailure.authRequired }
                var usage = try parseReport(data)
                usage.identity = .init(accountID: subject)
                let result = try NativeProviderNormalizer.normalize(usage, providerID: "antigravity", alias: alias, source: .officialAPI)
                guard expectedIdentity == nil || expectedIdentity == result.identityFingerprint else {
                    throw ProviderFailure.authRequired
                }
                try Task.checkCancellation()
                return NativeProviderProbeResult(accountID: result.accountID,
                    identityFingerprint: result.identityFingerprint, windows: result.windows)
            }
            throw ProviderFailure.authRequired
        } catch { throw NativeProvider.classify(error) }
    }

    private struct Report: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let id: String
                        let window: String?
                        let remainingFraction: Double?
                        let resetTime: String?
                        let enabled: Bool?
                        let disabled: Bool?
                    }
                    let buckets: [Bucket]
                }
                let groups: [Group]
            }
            let name: String
            let data: Payload
        }
        let status: String
        let command: Command
    }

    static func parseReport(_ data: Data) throws -> NativeUsage {
        guard data.count <= 1_048_576 else { throw ProviderFailure.outputLimit }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(Report.self, from: data),
              report.status == "SUCCESS", report.command.name == "usage" else { throw ProviderFailure.parseChanged }
        var windows: [NativeUsage.Window] = []
        var seen = Set<String>()
        for group in report.command.data.groups {
            for bucket in group.buckets {
                let minutes: Int
                switch bucket.id {
                case "gemini-5h", "3p-5h": minutes = 300
                case "gemini-weekly", "3p-weekly": minutes = 10_080
                default: continue
                }
                guard seen.insert(bucket.id).inserted else { throw ProviderFailure.parseChanged }
                guard bucket.enabled != false, bucket.disabled != true,
                      let fraction = bucket.remainingFraction else { continue }
                guard fraction.isFinite, (0...1).contains(fraction) else { throw ProviderFailure.parseChanged }
                let reset = bucket.resetTime.flatMap(NativeAPIParsing.date)
                if bucket.resetTime != nil && reset == nil { throw ProviderFailure.parseChanged }
                windows.append(.init(id: "antigravity-quota-summary-" + bucket.id,
                    usedPercent: (1 - fraction) * 100, windowMinutes: minutes, resetsAt: reset))
            }
        }
        guard !windows.isEmpty else { throw ProviderFailure.unsupported }
        return NativeUsage(extraWindows: windows)
    }

    /// go-keyring's gemini/antigravity item and agy's fallback file share this
    /// envelope. Only access_token leaves the decoder; no token is logged.
    static func accessToken(from data: Data) throws -> String {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw ProviderFailure.authRequired
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        let json = raw.hasPrefix(prefix) ? Data(base64Encoded: String(raw.dropFirst(prefix.count))) : Data(raw.utf8)
        guard let json, let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProviderFailure.authRequired
        }
        let payload = root["token"] as? [String: Any] ?? root
        guard let token = (payload["access_token"] ?? payload["accessToken"]) as? String,
              !token.isEmpty, token.utf8.count <= 32_768,
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ProviderFailure.authRequired
        }
        return token
    }

    static func storedAccessToken() async throws -> String {
        let result = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
            timeout: 10, maxBytes: 65_536)
        if result.exitCode == 0 { return try accessToken(from: result.output) }
        // Only a missing item permits file fallback. A locked or denied keychain
        // must not accidentally bind a different, stale file account.
        guard result.exitCode == 44 else { throw ProviderFailure.permissionDenied }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProviderFailure.authRequired }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw ProviderFailure.permissionDenied }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 65_537) else { throw ProviderFailure.authRequired }
        return try accessToken(from: data)
    }

    private static func googleSubject(_ token: String) async throws -> String {
        struct Identity: Decodable { let sub: String }
        let data = try await NativeHTTP.request("GET", URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!,
            headers: ["Authorization": "Bearer " + token], timeout: 15).data
        return try NativeHTTP.decode(Identity.self, from: data).sub
    }

    static func supportsUsageReport(_ version: String) -> Bool {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return false }
        return major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)))
    }

    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/agy"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/agy"), URL(fileURLWithPath: "/usr/local/bin/agy")]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard GitHubCLIProcess.secureLocation(candidate), let binary = GitHubCLIProcess.canonical(candidate),
                  FileManager.default.isExecutableFile(atPath: binary.path), CodexAppDiscovery.isNativeMachO(binary) else {
                throw ProviderFailure.permissionDenied
            }
            return binary
        }
        throw ProviderFailure.unsupported
    }

    static func environment(home: String, guardDirectory: URL, inherited: [String: String]) -> [String: String] {
        var env = ["HOME": home, "PATH": guardDirectory.path + ":/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                   "BROWSER": guardDirectory.appendingPathComponent("open").path,
                   "AGY_CLI_DISABLE_AUTO_UPDATE": "true", "NO_COLOR": "1"]
        for key in ["TMPDIR", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"] {
            env[key] = inherited[key]
        }
        return env
    }

    static func usageReport() async throws -> Data {
        let binary = try executable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ammo-agy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Failed silent sign-in must not open a browser during background refresh.
        for name in ["open", "xdg-open"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"),
                                            to: directory.appendingPathComponent(name))
        }
        let env = environment(home: FileManager.default.homeDirectoryForCurrentUser.path,
                              guardDirectory: directory, inherited: ProcessInfo.processInfo.environment)
        let version = try await GitHubCLIProcess.run(binary: binary, arguments: ["--version"], timeout: 5,
            verifyExecutableBeforeSpawn: true, maxBytes: 4096, environment: env, workingDirectory: directory)
        guard version.exitCode == 0, let text = String(data: version.output, encoding: .utf8),
              supportsUsageReport(text) else { throw ProviderFailure.unsupported }
        let result = try await GitHubCLIProcess.run(binary: binary, arguments: ["-p", "/usage", "--output-format", "json"],
            timeout: 90, verifyExecutableBeforeSpawn: true, maxBytes: 1_048_576,
            environment: env, workingDirectory: directory)
        guard result.exitCode == 0 else { throw ProviderFailure.authRequired }
        return result.output
    }
}
