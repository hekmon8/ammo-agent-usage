import Darwin
import Foundation
import CryptoKit
import QuotaCore

public struct ProviderDefinition: Sendable {
    public let id: String
    public let displayName: String
    public let source: SourceMethod
    public let experimental: Bool
    public let supportsHistory: Bool
    public init(id: String, displayName: String, source: SourceMethod, experimental: Bool = true, supportsHistory: Bool = false) {
        self.id = id; self.displayName = displayName; self.source = source; self.experimental = experimental; self.supportsHistory = supportsHistory
    }
}
public enum ProviderFailure: Error, Sendable, Equatable {
    case authRequired, rateLimited(seconds: Int), network, timeout, parseChanged, unsupported, permissionDenied, cancelled, outputLimit
}
public protocol QuotaProvider: Sendable {
    var definition: ProviderDefinition { get }
    var accountID: String { get }
    var credentialIdentity: String { get }
    func fetch(now: Date) async throws -> [QuotaWindow]
    /// A partial result may include a source-specific rate limit.
    func retryNotBefore() async -> Date?
    func githubExpenseObservedAt() async -> Date?
}

public extension QuotaProvider {
    var credentialIdentity: String { accountID }
    func retryNotBefore() async -> Date? { nil }
    func githubExpenseObservedAt() async -> Date? { nil }
}

actor ProviderRetryDeadline {
    private var value: Date?
    func set(_ value: Date?) { self.value = value }
    func get() -> Date? { value }
}

public enum CodexNormalizer {
    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let rateLimitResetCredits: ResetCredits?
    }
    private struct Bucket: Decodable { let primary: Window?; let secondary: Window?; let credits: Credits?; let individualLimit: IndividualLimit? }
    private struct Credits: Decodable { let hasCredits: Bool; let unlimited: Bool; let balance: String? }
    private struct IndividualLimit: Decodable { let limit: String; let used: String; let remainingPercent: Decimal; let resetsAt: Int64? }
    private struct ResetCredits: Decodable { let availableCount: Int64; let nextExpiresAt: Int64? }
    private struct Window: Decodable { let usedPercent: Decimal; let windowDurationMins: Int64?; let resetsAt: Int64? }
    public static func normalize(_ data: Data, accountID: String, alias: String, now: Date,
                                 source: SourceMethod = .localRPC) throws -> [QuotaWindow] {
        guard data.count <= 1_048_576 else { throw ProviderFailure.outputLimit }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw ProviderFailure.parseChanged }
        let buckets = response.rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? response.rateLimits.map { ["default": $0] } ?? [:]
        var result: [QuotaWindow] = []
        for (bucketID, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            guard bucketID.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil else { throw ProviderFailure.parseChanged }
            for (kind, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                let bps: Int
                do { bps = try QuotaRules.remainingBps(usedPercent: NSDecimalNumber(decimal: window.usedPercent).stringValue) }
                catch { throw ProviderFailure.parseChanged }
                let duration: Int?
                if let minutes = window.windowDurationMins {
                    guard minutes > 0, minutes <= 527_040 else { throw ProviderFailure.parseChanged }
                    duration = Int(minutes * 60)
                } else { duration = nil }
                let reset = window.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
                let key = bucketID == "default" ? kind : "\(bucketID)-\(kind)"
                result.append(.reported(id: "codex-\(key)", providerID: "codex", accountID: accountID, alias: alias,
                                        key: key, remainingBps: bps, observedAt: now, staleAt: now.addingTimeInterval(600),
                                        duration: duration, resetsAt: reset, source: source))
            }
        }
        // The legacy view mirrors the account bucket. Credits are one shared balance,
        // not an amount to sum across Codex / Spark rate-limit buckets.
        let credits = response.rateLimits?.credits ?? buckets["codex"]?.credits ?? buckets["default"]?.credits
            ?? (buckets.count == 1 ? buckets.values.first?.credits : nil)
        func amountWindow(key: String, unit: QuotaWindow.Unit, amount: String?, unlimited: Bool = false, deadline: Date? = nil) -> QuotaWindow {
            .providerValue(id: "codex-\(key)", providerID: "codex", accountID: accountID, alias: alias,
                           key: key, unit: unit, currency: nil, availability: unlimited ? .unlimited : .available,
                           remainingBps: nil, amount: amount, limit: nil, quality: .reported, source: source,
                           observedAt: now, staleAt: now.addingTimeInterval(600), windowKind: .unknown,
                           duration: nil, resetsAt: deadline)
        }
        if let credits {
            if credits.unlimited {
                result.append(amountWindow(key: "credit-balance", unit: .credits, amount: nil, unlimited: true))
            } else if let balance = credits.balance {
                guard balance.range(of: "^(0|[1-9][0-9]*)(\\.[0-9]{1,12})?$", options: .regularExpression) != nil,
                      balance.utf8.count <= 48,
                      let number = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN, number >= 0 else { throw ProviderFailure.parseChanged }
                result.append(amountWindow(key: "credit-balance", unit: .credits, amount: balance))
            }
            // hasCredits=false alone does not prove a measured zero balance.
        }
        let individual = response.rateLimits?.individualLimit ?? buckets["codex"]?.individualLimit
            ?? buckets["default"]?.individualLimit ?? (buckets.count == 1 ? buckets.values.first?.individualLimit : nil)
        if let individual {
            func decimal(_ value: String) throws -> Decimal {
                guard value.utf8.count <= 48,
                      value.range(of: "^(0|[1-9][0-9]*)(\\.[0-9]{1,12})?$", options: .regularExpression) != nil,
                      let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN, number >= 0 else { throw ProviderFailure.parseChanged }
                return number
            }
            let limit = try decimal(individual.limit), used = try decimal(individual.used)
            let bps: Int
            do { bps = try QuotaRules.remainingBps(usedPercent: NSDecimalNumber(decimal: 100 - individual.remainingPercent).stringValue) }
            catch { throw ProviderFailure.parseChanged }
            result.append(.providerValue(id: "codex-monthly-credit-limit", providerID: "codex", accountID: accountID,
                alias: alias, key: "monthly-credit-limit", unit: .credits, currency: nil,
                remainingBps: bps, amount: NSDecimalNumber(decimal: max(0, limit - used)).stringValue,
                limit: individual.limit, quality: .reported, source: source, observedAt: now,
                staleAt: now.addingTimeInterval(600), windowKind: individual.resetsAt == nil ? .unknown : .fixed, duration: nil,
                resetsAt: individual.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }))
        }
        if let resets = response.rateLimitResetCredits {
            guard resets.availableCount >= 0 else { throw ProviderFailure.parseChanged }
            result.append(amountWindow(key: "rate-limit-reset-credits", unit: .requests, amount: String(resets.availableCount),
                deadline: resets.availableCount > 0 ? resets.nextExpiresAt.map { Date(timeIntervalSince1970: Double($0)) } : nil))
        }
        guard !result.isEmpty else { throw ProviderFailure.unsupported }
        guard result.count <= SnapshotCodec.maxWindows else { throw ProviderFailure.outputLimit }
        // An absent quota window is not an invented unavailable bucket.
        return result
    }
}

public struct CodexProvider: QuotaProvider {
    public let definition = ProviderDefinition(id: "codex", displayName: "Codex", source: .localRPC)
    public let accountID: String
    public let alias: String
    public let executable: ApprovedExecutable
    public let credentialIdentity: String
    public let profile: CodexInstanceProfile?
    public init(executable: ApprovedExecutable, accountID: String, alias: String, expectedIdentity: String, profile: CodexInstanceProfile? = nil) {
        self.executable = executable; self.accountID = accountID; self.alias = alias; self.credentialIdentity = expectedIdentity
        self.profile = profile
    }
    public func fetch(now: Date) async throws -> [QuotaWindow] {
        guard let profile else { throw ProviderFailure.authRequired }
        let result = try await BoundedRPC.read(executable: executable.verifiedURL(), arguments: CodexInstanceProfile.appServerArguments, timeout: 15, environment: try profile.environment())
        guard result.identityFingerprint == credentialIdentity else { throw ProviderFailure.authRequired }
        return try CodexNormalizer.normalize(result.limits, accountID: accountID, alias: alias, now: now)
    }
}

/// Construct only after the user selects the executable in the connection flow.
/// Native CLIs may update at the selected location, so every launch re-resolves
/// and revalidates the current signed Mach-O inside its OpenAI app bundle.
public struct ApprovedExecutable: Codable, Sendable {
    public let path: URL
    /// SHA-256 of the binary at approval time, retained only for configuration
    /// compatibility with earlier releases; it no longer gates fetches.
    private let digest: Data
    public init(userSelectedURL: URL) throws {
        let selected = userSelectedURL.standardizedFileURL
        guard selected.isFileURL, let resolved = Self.verifiedTarget(of: selected),
              FileManager.default.isExecutableFile(atPath: resolved.path) else { throw ProviderFailure.permissionDenied }
        path = selected
        digest = Data(SHA256.hash(data: try Data(contentsOf: resolved)))
    }

    /// Re-resolves the current executable behind a connection's approved
    /// location, following launcher symlinks and in-place CLI updates.
    private static func verifiedTarget(of location: URL) -> URL? {
        let resolved = location.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        var info = stat()
        let fileManager = FileManager.default
        guard resolved.isFileURL,
              fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolved.path),
              stat(resolved.path, &info) == 0, info.st_uid == getuid(),
              CodexAppDiscovery.isNativeMachO(resolved),
              CodexAppDiscovery.isOpenAISigned(resolved) else { return nil }
        return resolved
    }

    public func verifiedURL() throws -> URL {
        guard let resolved = Self.verifiedTarget(of: path) else { throw ProviderFailure.permissionDenied }
        return resolved
    }
}
