import Foundation
import QuotaCore

/// Existing gh login is owned by gh. Only bounded `gh api --method GET`
/// results enter this provider; tokens/config/keychain never enter Ammo.
public struct GitHubCLIProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "github-actions", displayName: "GitHub Actions", source: .officialAPI)
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String
    public let organization: String?
    private let retryDeadline = ProviderRetryDeadline()
    private let expenseObservation = ProviderRetryDeadline()
    public func githubExpenseObservedAt() async -> Date? { await expenseObservation.get() }

    public func retryNotBefore() async -> Date? {
        let local = await retryDeadline.get()
        let shared = await GitHubRequestGate.shared.deadline(key: GitHubRequestGate.cliKey)
        return [local, shared].compactMap { $0 }.filter { $0 > Date() }.max()
    }

    public init(accountID: String, alias: String, expectedIdentity: String, organization: String?) {
        self.accountID = accountID; self.alias = alias
        self.credentialIdentity = expectedIdentity; self.organization = organization
    }

    public static func probe(alias: String, organization: String?) async throws -> NativeProviderProbeResult {
        let report = try await read(organization: organization, includeBudgets: false)
        return try normalized(report, alias: alias)
    }

    public func fetch(now: Date) async throws -> [QuotaWindow] {
        try await fetch(now: now, request: Self.liveRequest)
    }

    func fetch(now: Date, request: GitHubBillingReader.Request) async throws -> [QuotaWindow] {
        do {
            let report = try await Self.read(organization: organization, includeBudgets: false,
                                             now: now, expectedIdentity: credentialIdentity, request: request)
            let result = try GitHubBillingReader.normalized(report, alias: alias)
            guard result.accountID == accountID else { throw ProviderFailure.authRequired }
            await retryDeadline.set(result.retryNotBefore)
            await expenseObservation.set(result.expenseObservedAt)
            return result.windows
        } catch {
            throw GitHubBillingReader.classify(error)
        }
    }

    public func report() async throws -> GitHubBillingReport {
        let report = try await Self.read(organization: organization, includeBudgets: true,
                                        expectedIdentity: credentialIdentity)
        guard try Self.normalized(report, alias: alias).accountID == accountID else { throw ProviderFailure.authRequired }
        return report
    }

    static func normalized(_ report: GitHubBillingReport, alias: String) throws -> NativeProviderProbeResult {
        let result = try GitHubBillingReader.normalized(report, alias: alias)
        return .init(accountID: result.accountID, identityFingerprint: result.identityFingerprint,
                     windows: result.windows, retryNotBefore: result.retryNotBefore, expenseObservedAt: result.expenseObservedAt)
    }

    static func read(organization: String?, includeBudgets: Bool, now: Date = Date(),
                     expectedIdentity: String? = nil,
                     request: GitHubBillingReader.Request = liveRequest) async throws -> GitHubBillingReport {
        try await GitHubBillingReader.load(organization: organization, now: now, includeBudgets: includeBudgets,
            headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": GitHubBillingReader.apiVersion],
            request: request, validateIdentity: { identity in
                let scope = organization == nil ? "user" : "organization"
                let usage = NativeUsage(identity: .init(accountID: "\(scope):\(identity.id)"))
                let pin = try NativeProviderNormalizer.identity(usage, providerID: "github-actions")
                guard expectedIdentity == nil || pin == expectedIdentity else { throw ProviderFailure.authRequired }
            })
    }

    static func arguments(url: URL, headers: [String: String]) throws -> [String] {
        guard url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              headers == ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": GitHubBillingReader.apiVersion],
              url.path == "/user" || url.path.range(of: "^/(orgs/[A-Za-z0-9-]{1,39}|(?:users|organizations)/[A-Za-z0-9-]{1,39}/settings/billing/(?:usage/summary|budgets))$",
                                                    options: .regularExpression) != nil else { throw ProviderFailure.permissionDenied }
        let endpoint = url.path + (url.query.map { "?" + $0 } ?? "")
        return ["api", "--hostname", "github.com", "--method", "GET", "--include",
                "--header", "Accept: application/vnd.github+json",
                "--header", "X-GitHub-Api-Version: " + GitHubBillingReader.apiVersion, "--", endpoint]
    }

    static func liveRequest(_ url: URL, _ headers: [String: String]) async throws -> Data {
        let args = try arguments(url: url, headers: headers)
        let binary = try GitHubCLIProcess.executable()
        return try await GitHubRequestGate.shared.request(key: GitHubRequestGate.cliKey) {
            try response(await GitHubCLIProcess.run(binary: binary, arguments: args, verifyExecutableBeforeSpawn: true))
        }
    }

    static func response(_ result: GitHubCLIProcess.Result, now: Date = Date()) throws -> Data {
        if result.exitCode == 4 { throw GitHubCLIFailure.notLoggedIn }
        guard let text = String(data: result.output, encoding: .utf8),
              let boundary = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") else {
            throw ProviderFailure.network
        }
        let headers = text[..<boundary.lowerBound]
        guard headers.utf8.count <= 65_536,
              let line = headers.split(separator: "\n").first else { throw ProviderFailure.parseChanged }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let status = Int(fields[1]) else {
            throw ProviderFailure.parseChanged
        }
        var rateHeaders: [String: String] = [:]
        for row in headers.components(separatedBy: .newlines).dropFirst() {
            let pair = row.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                rateHeaders[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let retry = GitHubRateLimitFailure.deadline(status: status, headers: rateHeaders, receivedAt: now) {
            throw GitHubRateLimitFailure(retryNotBefore: retry)
        }
        switch status {
        case 200: break
        case 401: throw GitHubCLIFailure.notLoggedIn
        case 403: throw GitHubCLIFailure.billingDenied
        case 404: throw GitHubCLIFailure.billingUnavailable
        default: throw ProviderFailure.network
        }
        guard result.exitCode == 0 else { throw ProviderFailure.network }
        let body = Data(text[boundary.upperBound...].utf8)
        guard body.count <= 2_097_152 else { throw ProviderFailure.outputLimit }
        return body
    }
}
