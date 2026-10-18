import CryptoKit
import Foundation
import QuotaCore

public struct NativeProviderProbeResult: Sendable {
    public let accountID: String
    public let identityFingerprint: String
    public let windows: [QuotaWindow]
    public var retryNotBefore: Date? = nil
    public var expenseObservedAt: Date? = nil
    public init(accountID: String, identityFingerprint: String, windows: [QuotaWindow], retryNotBefore: Date? = nil, expenseObservedAt: Date? = nil) {
        self.accountID = accountID; self.identityFingerprint = identityFingerprint
        self.windows = windows; self.retryNotBefore = retryNotBefore; self.expenseObservedAt = expenseObservedAt
    }
}

/// A credential-backed connection to one of the self-developed native API
/// clients. The credential is loaded from the instance vault by the caller.
public struct NativeProvider: QuotaProvider {
    public let definition: ProviderDefinition
    public let accountID: String
    public let alias: String
    public let credentialIdentity: String

    private let providerID: String
    private let credential: NativeProviderCredential
    private let retryDeadline = ProviderRetryDeadline()
    private let expenseObservation = ProviderRetryDeadline()
    public func githubExpenseObservedAt() async -> Date? { await expenseObservation.get() }

    public func retryNotBefore() async -> Date? {
        let local = await retryDeadline.get()
        guard providerID == "github-actions" else { return local }
        let key = GitHubRequestGate.key(forAuthorization: "Bearer " + credential.value)
        let shared = await GitHubRequestGate.shared.deadline(key: key)
        return [local, shared].compactMap { $0 }.filter { $0 > Date() }.max()
    }

    public init(
        providerID: String,
        accountID: String,
        alias: String,
        expectedIdentity: String, sourceAccountID: String? = nil, credential: NativeProviderCredential) throws
    {
        let descriptor = try NativeProviderCatalog.validateAPI(providerID: providerID)
        guard !alias.isEmpty, alias.count <= 48,
              expectedIdentity.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw ProviderFailure.parseChanged }
        try credential.validated()
        self.definition = ProviderDefinition(
            id: descriptor.id,
            displayName: descriptor.displayName,
            source: .officialAPI)
        self.providerID = descriptor.id
        self.credential = credential
        self.accountID = accountID
        self.alias = alias
        self.credentialIdentity = expectedIdentity
    }

    public struct SourceAccount: Identifiable, Sendable {
        public let id: String
        public let label: String
    }

    public static func supportedCredentialKinds(providerID: String) -> Set<NativeProviderCredential.Kind> {
        NativeProviderCatalog.supportedCredentialKinds(providerID: providerID)
    }

    public static func probe(
        providerID: String,
        alias: String, sourceAccountID: String? = nil, credential: NativeProviderCredential) async throws -> NativeProviderProbeResult
    {
        do {
            let result = try await fetchReference(providerID: providerID, alias: alias, credential: credential)
            _ = try Snapshot.make(
                windows: result.windows,
                deviceID: "provider-probe",
                epoch: "provider-probe",
                sequence: 1,
                capturedAt: Date())
            return NativeProviderProbeResult(
                accountID: result.accountID,
                identityFingerprint: result.identityFingerprint,
                windows: result.windows, retryNotBefore: result.retryNotBefore, expenseObservedAt: result.expenseObservedAt)
        } catch {
            throw classify(error)
        }
    }

    public func fetch(now _: Date) async throws -> [QuotaWindow] {
        do {
            let result = try await Self.fetchReference(providerID: providerID, alias: alias, credential: credential)
            guard result.identityFingerprint == credentialIdentity, result.accountID == accountID else {
                throw ProviderFailure.authRequired
            }
            await retryDeadline.set(result.retryNotBefore)
            await expenseObservation.set(result.expenseObservedAt)
            return result.windows
        } catch {
            throw Self.classify(error)
        }
    }

    private static func fetchReference(
        providerID: String,
        alias: String, credential: NativeProviderCredential) async throws -> NativeProviderNormalizationResult
    {
        let descriptor = try NativeProviderCatalog.validateAPI(providerID: providerID)
        if providerID == "github-actions" {
            let report = try await GitHubBillingReader.report(credential, includeBudgets: false)
            return try GitHubBillingReader.normalized(report, alias: alias)
        }
        let usage = try await NativeProviderAPI.fetch(providerID: descriptor.id, credential: credential)
        return try NativeProviderNormalizer.normalize(
            usage,
            providerID: providerID,
            alias: alias,
            source: .officialAPI)
    }

    static func classify(_ error: Error) -> ProviderFailure {
        if let failure = error as? GitHubIdentityReadFailure { return failure.reason }
        if let failure = error as? GitHubRateLimitFailure { return .rateLimited(seconds: failure.secondsRemaining()) }
        if let failure = error as? ProviderFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let classified = error as? NativeProviderAPIError {
            switch classified {
            case .authenticationRequired: return .authRequired
            case .permissionDenied: return .permissionDenied
            case .rateLimited(let seconds): return .rateLimited(seconds: seconds ?? 300)
            case .unavailable: return .network
            case .parseFailure: return .parseChanged
            case .credentialRejected: return .authRequired
            }
        }
        if let http = error as? NativeHTTP.Failure { return NativeHTTP.classify(http) }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .network
            }
        }
        return .parseChanged
    }
}

public struct NativeProviderNormalizationResult: Sendable {
    public let windows: [QuotaWindow]
    public let identityFingerprint: String
    public let accountID: String
    public var retryNotBefore: Date? = nil
    public var expenseObservedAt: Date? = nil
}

public enum NativeProviderNormalizer {
    public static func normalize(
        _ usage: NativeUsage,
        providerID: String,
        alias: String,
        source: SourceMethod) throws -> NativeProviderNormalizationResult
    {
        guard !alias.isEmpty, alias.count <= 48 else { throw ProviderFailure.parseChanged }
        let identityFingerprint = try identity(usage, providerID: providerID)
        let accountID = "native-" + String(identityFingerprint.prefix(32))
        let quality: QuotaWindow.Quality = usage.confidence == .estimated ? .estimated : .reported
        var windows: [QuotaWindow] = []
        for (key, window) in [
            ("primary", usage.primary),
            ("secondary", usage.secondary),
            ("tertiary", usage.tertiary),
        ] {
            if let window {
                windows.append(try percentWindow(
                    window, providerID: providerID, accountID: accountID, alias: alias,
                    key: key, observedAt: usage.updatedAt, quality: quality, source: source))
            }
        }
        var extraKeys = Set<String>()
        for extra in usage.extraWindows {
            // A renewal date is not a measured zero-percent usage window.
            if providerID == "opencodego", extra.id == "renewal" { continue }
            guard !extra.id.isEmpty, extra.id.utf8.count <= 512, !extra.id.contains("\0") else {
                throw ProviderFailure.parseChanged
            }
            let key = safeExtraKey(extra.id)
            guard extraKeys.insert(key).inserted else { throw ProviderFailure.parseChanged }
            if let amount = extra.amountWindow {
                windows.append(try amountValueWindow(
                    extra, amount, providerID: providerID, accountID: accountID, alias: alias,
                    key: key, observedAt: usage.updatedAt, quality: quality, source: source))
                continue
            }
            windows.append(try percentWindow(
                extra, providerID: providerID, accountID: accountID, alias: alias,
                key: key, observedAt: usage.updatedAt, quality: quality, source: source))
        }
        if let cost = usage.cost {
            windows.append(contentsOf: try costWindows(
                cost, providerID: providerID, accountID: accountID, alias: alias,
                observedAt: usage.updatedAt, quality: quality, source: source))
        }
        guard !windows.isEmpty else { throw ProviderFailure.unsupported }
        guard windows.count <= SnapshotCodec.maxWindows, Set(windows.map(\.id)).count == windows.count else {
            throw ProviderFailure.outputLimit
        }
        return NativeProviderNormalizationResult(
            windows: windows,
            identityFingerprint: identityFingerprint,
            accountID: accountID)
    }

    static func identity(_ usage: NativeUsage, providerID: String) throws -> String {
        let organization = clean(usage.identity.organization)
        if let organization, organization.utf8.count > 512 {
            throw ProviderFailure.parseChanged
        }
        let scope = organization.map { "\norganization=\($0)" } ?? ""
        if let accountID = clean(usage.identity.accountID) {
            guard accountID.utf8.count <= 512 else { throw ProviderFailure.parseChanged }
            return sha256("automatic-account-id\n\(providerID)\n\(accountID)\(scope)")
        }
        if let email = clean(usage.identity.email) {
            guard email.utf8.count <= 512, email.contains("@") else { throw ProviderFailure.parseChanged }
            return sha256("automatic-account-email\n\(providerID)\n\(email.lowercased())\(scope)")
        }
        guard let identitySeed = usage.identitySeed else { throw ProviderFailure.authRequired }
        guard identitySeed.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ProviderFailure.parseChanged
        }
        return sha256("automatic-source\n\(providerID)\n\(identitySeed)")
    }

    private static func clean(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func percentWindow(
        _ window: NativeUsage.Window,
        providerID: String,
        accountID: String,
        alias: String,
        key: String,
        observedAt: Date,
        quality: QuotaWindow.Quality,
        source: SourceMethod) throws -> QuotaWindow
    {
        guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
            throw ProviderFailure.parseChanged
        }
        let bps: Int
        do { bps = try QuotaRules.remainingBps(usedPercent: try decimal(window.usedPercent)) }
        catch { throw ProviderFailure.parseChanged }
        let duration: Int?
        if let minutes = window.windowMinutes {
            guard minutes > 0, minutes <= 527_040 else { throw ProviderFailure.parseChanged }
            duration = minutes * 60
        } else {
            duration = nil
        }
        return .providerValue(
            id: stableWindowID(providerID: providerID, accountID: accountID, key: key),
            providerID: providerID,
            accountID: accountID,
            alias: alias,
            key: key,
            unit: .percent,
            currency: nil,
            remainingBps: bps,
            amount: nil,
            limit: nil,
            quality: quality,
            source: source,
            observedAt: observedAt,
            staleAt: observedAt.addingTimeInterval(600),
            windowKind: duration == nil ? .unknown : .rolling,
            duration: duration,
            resetsAt: window.resetsAt)
    }

    /// Amount windows carry a counter (e.g. available reset cards) rather than
    /// a measured remaining percent; remainingBps stays nil so every surface
    /// renders the reported amount verbatim instead of a derived percentage.
    private static func amountValueWindow(
        _ window: NativeUsage.Window,
        _ amount: NativeUsage.AmountWindow,
        providerID: String,
        accountID: String,
        alias: String,
        key: String,
        observedAt: Date,
        quality: QuotaWindow.Quality,
        source: SourceMethod) throws -> QuotaWindow
    {
        guard amount.value >= 0, amount.value <= 99_999 else { throw ProviderFailure.parseChanged }
        return .providerValue(
            id: stableWindowID(providerID: providerID, accountID: accountID, key: key),
            providerID: providerID,
            accountID: accountID,
            alias: alias,
            key: key,
            unit: amount.unit,
            currency: nil,
            remainingBps: nil,
            amount: String(amount.value),
            limit: nil,
            quality: quality,
            source: source,
            observedAt: observedAt,
            staleAt: observedAt.addingTimeInterval(600),
            windowKind: .unknown,
            duration: nil,
            resetsAt: window.resetsAt)
    }

    private static func costWindows(
        _ cost: NativeUsage.Cost,
        providerID: String,
        accountID: String,
        alias: String,
        observedAt: Date,
        quality: QuotaWindow.Quality,
        source: SourceMethod) throws -> [QuotaWindow]
    {
        guard cost.used.isFinite, cost.limit.isFinite, cost.used >= 0, cost.limit >= 0,
              cost.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
              cost.balance?.isFinite != false, (cost.balance.map { $0 >= 0 }) != false,
              cost.freeBalance?.isFinite != false, (cost.freeBalance.map { $0 >= 0 }) != false
        else { throw ProviderFailure.parseChanged }
        var windows: [QuotaWindow] = []
        if (providerID == "grok" && cost.period == "Prepaid credits") ||
            (providerID == "opencodego" && cost.period == "Zen balance") ||
            (providerID == "factory" && cost.period == "Extra usage balance") {
            windows.append(moneyWindow(
                providerID: providerID, accountID: accountID, alias: alias, key: "balance",
                amount: try decimal(cost.used), limit: nil, remainingBps: nil, quality: quality,
                currency: cost.currency, source: source, observedAt: observedAt, resetsAt: nil))
            return windows
        }
        if let balance = cost.balance {
            windows.append(moneyWindow(
                providerID: providerID, accountID: accountID, alias: alias, key: "balance",
                amount: try decimal(balance), limit: nil, remainingBps: nil, quality: quality,
                currency: cost.currency, source: source, observedAt: observedAt, resetsAt: nil))
        }
        if let freeBalance = cost.freeBalance, freeBalance > 0 {
            windows.append(moneyWindow(
                providerID: providerID, accountID: accountID, alias: alias, key: "free-balance",
                amount: try decimal(freeBalance), limit: nil, remainingBps: nil, quality: quality,
                currency: cost.currency, source: source, observedAt: observedAt,
                resetsAt: cost.freeResetsAt))
        }
        if cost.limit > 0 {
            let boundedUsed = min(cost.limit, cost.used)
            let remaining = max(0, cost.limit - cost.used)
            let remainingBps = Int(((1 - boundedUsed / cost.limit) * 10_000).rounded())
            windows.append(moneyWindow(
                providerID: providerID, accountID: accountID, alias: alias, key: "cost-budget",
                amount: try decimal(remaining), limit: try decimal(cost.limit), remainingBps: remainingBps,
                quality: quality, currency: cost.currency, source: source,
                observedAt: observedAt, resetsAt: cost.resetsAt, startsAt: cost.startsAt, periodID: cost.periodID))
        } else if cost.used > 0 || cost.reportsSpend {
            // Preserve reported spend even when the provider has no matching
            // budget. It is a money value and must not be invented as percent.
            windows.append(moneyWindow(
                providerID: providerID, accountID: accountID, alias: alias, key: "cost-spend",
                amount: try decimal(cost.used), limit: nil, remainingBps: nil, quality: quality,
                currency: cost.currency, source: source,
                observedAt: observedAt, resetsAt: cost.resetsAt, startsAt: cost.startsAt, periodID: cost.periodID))
        }
        return windows
    }

    private static func moneyWindow(
        providerID: String,
        accountID: String,
        alias: String,
        key: String,
        amount: String,
        limit: String?,
        remainingBps: Int?,
        quality: QuotaWindow.Quality,
        currency: String,
        source: SourceMethod,
        observedAt: Date,
        resetsAt: Date?, startsAt: Date? = nil, periodID: String? = nil) -> QuotaWindow
    {
        .providerValue(
            id: stableWindowID(providerID: providerID, accountID: accountID, key: key),
            providerID: providerID,
            accountID: accountID,
            alias: alias,
            key: key,
            unit: .money,
            currency: currency,
            remainingBps: remainingBps,
            amount: amount,
            limit: limit,
            quality: quality,
            source: source,
            observedAt: observedAt,
            staleAt: observedAt.addingTimeInterval(600),
            windowKind: resetsAt == nil ? .unknown : .fixed,
            duration: nil,
            resetsAt: resetsAt, startsAt: startsAt, periodID: periodID)
    }

    private static func safeExtraKey(_ raw: String) -> String {
        if raw.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", options: .regularExpression) != nil {
            return raw
        }
        return "extra-" + String(sha256(raw).prefix(24))
    }

    static func stableWindowID(providerID: String, accountID: String, key: String) -> String {
        "native-" + String(sha256(providerID + "\n" + accountID + "\n" + key).prefix(40))
    }

    static func decimal(_ value: Double) throws -> String {
        guard value.isFinite, value >= 0 else { throw ProviderFailure.parseChanged }
        var result = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        if result == "-0" || result.isEmpty { result = "0" }
        guard result.utf8.count <= 48,
              result.range(of: "^(0|[1-9][0-9]*)(\\.[0-9]{1,12})?$", options: .regularExpression) != nil
        else { throw ProviderFailure.outputLimit }
        return result
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
