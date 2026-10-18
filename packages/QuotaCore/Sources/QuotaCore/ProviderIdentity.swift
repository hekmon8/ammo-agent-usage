import Foundation

/// Stable, credential-free metadata used to identify a provider consistently on
/// every surface. Colors are expressed as semantic tones so QuotaCore stays free
/// of UI framework dependencies.
public enum ProviderTone: String, Sendable, Codable, CaseIterable {
    case teal
    case terracotta
    case blue
    case violet
    case moss
    case amber
}

public struct ProviderIdentity: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let monogram: String
    public let systemSymbol: String
    public let tone: ProviderTone

    public init(
        id: String,
        displayName: String,
        shortName: String,
        monogram: String,
        systemSymbol: String,
        tone: ProviderTone
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.monogram = monogram
        self.systemSymbol = systemSymbol
        self.tone = tone
    }
}

public enum ProviderCatalog {
    public static func identity(for providerID: String) -> ProviderIdentity {
        let fallback = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = fallback.lowercased()
        let known: ProviderIdentity? = switch normalized {
        case "codex", "codex-cli": identity(providerID, "Codex", "C", "terminal", .teal)
        case "openai": identity(providerID, "OpenAI", "O", "sparkle", .moss)
        case "claude", "anthropic", "claude-code": identity(providerID, "Claude", "C", "text.bubble", .terracotta)
        case "workbuddy", "codebuddy": identity(providerID, "WorkBuddy", "W", "briefcase.fill", .blue)
        case "zai", "z.ai", "z-ai", "glm", "zhipu", "zhipuai": identity(providerID, "z.ai / GLM", "G", "network", .blue)
        case "zcode": identity(providerID, "ZCode", "Z", "arrow.counterclockwise.circle", .blue)
        case "gemini", "google-gemini": identity(providerID, "Gemini", "G", "sparkles", .violet)
        case "copilot", "github-copilot": identity(providerID, "GitHub Copilot", "C", "chevron.left.forwardslash.chevron.right", .blue)
        case "github-actions": identity(providerID, "GitHub Actions", "GH", "arrow.triangle.branch", .blue)
        case "cursor": identity(providerID, "Cursor", "C", "cursorarrow.rays", .moss)
        case "factory", "droid", "factory-droid": identity(providerID, "Droid", "D", "hammer", .terracotta)
        case "antigravity": identity(providerID, "Antigravity", "A", "arrow.up.circle", .violet)
        case "alibaba", "qwen", "dashscope": identity(providerID, "Alibaba Qwen", "Q", "cloud", .amber)
        case "opencode", "open-code": identity(providerID, "OpenCode", "O", "terminal.fill", .teal)
        case "opencodego", "opencode-go": identity(providerID, "OpenCode Go", "O", "terminal.fill", .teal)
        case "replit": identity(providerID, "Replit", "R", "square.stack.3d.up", .moss)
        case "fal": identity(providerID, "fal", "F", "sparkles", .moss)
        case "vercel": identity(providerID, "Vercel", "V", "triangle.fill", .moss)
        case "cloudflare": identity(providerID, "Cloudflare", "CF", "cloud.fill", .moss)
        case "openrouter", "open-router": identity(providerID, "OpenRouter", "O", "arrow.triangle.branch", .violet)
        case "manus": identity(providerID, "Manus", "M", "hand.raised.fill", .amber)
        case "amp": identity(providerID, "Amp", "A", "bolt.fill", .terracotta)
        case "grok": identity(providerID, "Grok", "G", "bubble.left.and.text.bubble.right", .moss)
        case "deepseek": identity(providerID, "DeepSeek", "D", "waveform.path.ecg", .blue)
        case "kimi", "moonshot": identity(providerID, "Kimi", "K", "moon", .blue)
        case "minimax", "mini-max": identity(providerID, "MiniMax", "M", "waveform", .terracotta)
        default: nil
        }
        if let known { return known }

        let displayName = fallback.isEmpty ? "Provider" : fallback
        let shortName = displayName.count > 20 ? String(displayName.prefix(17)) + "…" : displayName
        let monogram = displayName.first.map { String($0).uppercased() } ?? "P"
        return ProviderIdentity(id: providerID, displayName: displayName, shortName: shortName, monogram: monogram, systemSymbol: "circle.grid.2x2", tone: .moss)
    }

    private static func identity(_ id: String, _ name: String, _ monogram: String, _ symbol: String, _ tone: ProviderTone) -> ProviderIdentity {
        ProviderIdentity(id: id, displayName: name, shortName: name, monogram: monogram, systemSymbol: symbol, tone: tone)
    }
}

public extension QuotaWindow {
    var isConsumptionMetric: Bool { ["cost-spend", "spend", "monthly-spend"].contains(quotaKey.lowercased()) }

    /// Reset-card windows count available manual resets rather than a
    /// remaining allowance; several surfaces special-case their copy.
    var isResetCardWindow: Bool {
        quotaKey == "rate-limit-reset-credits" || quotaKey == "rate-limit-reset-credits-week"
    }

    /// A window with nothing used and no reset reported (Factory/Droid is the
    /// live example): the provider runs no countdown yet — rolling windows
    /// only start with the first request — so surfaces name that state
    /// instead of falling back to a generic freshness status.
    var isIdleWindow: Bool {
        unit == .percent && remainingBps == 10_000 && window.resetsAt == nil
    }

    /// The actual duration is authoritative. A primary bucket may be weekly.
    var shortDisplayName: String {
        Self.shortDisplayName(providerID: providerId, quotaKey: quotaKey, unit: unit,
                              windowDurationSeconds: window.durationSeconds)
    }

    /// Names a quota from non-private semantics, including widget catalog entries.
    /// A missing duration stays unknown rather than assuming a primary period.
    static func shortDisplayName(providerID: String, quotaKey: String, unit: Unit,
                                 windowDurationSeconds: Int?) -> String {
        let providerId = providerID
        let key = quotaKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let period = Self.periodLabel(seconds: windowDurationSeconds)
        if key == "rate-limit-reset-credits" { return L("quota.label.remainingResets") }
        if key == "rate-limit-reset-credits-week" { return L("quota.label.remainingWeekResets") }
        if providerId == "antigravity" {
            let family: String? = if key == "primary" || key.hasPrefix("antigravity-quota-summary-gemini-") {
                L("quota.label.geminiShared")
            } else if key == "secondary" || key.hasPrefix("antigravity-quota-summary-3p-") {
                L("quota.label.claudeGptShared")
            } else { nil }
            if let family { return period.map { "\(family) · \($0)" } ?? family }
            // Detailed fallback responses can contain distinct model IDs. Keep those
            // visible instead of collapsing every model to an anonymous period label.
            let modelID = key.replacingOccurrences(of: "antigravity-compact-fallback-", with: "")
            if modelID.range(of: "^(gemini|claude|gpt)[-_][a-z0-9._-]+$", options: .regularExpression) != nil {
                return period.map { "\(modelID) · \($0)" } ?? modelID
            }
        }
        if providerId == "codex" || providerId == "codex-cli" {
            if key == "credit-balance" { return L("quota.label.creditBalance") }
            if key == "monthly-credit-limit" { return L("quota.label.monthlyCreditLimit") }
            let sparkKeys = ["codex-spark", "codex-spark-weekly", "codex_bengalfox-primary", "codex_bengalfox-secondary", "codex-spark-primary", "codex-spark-secondary", "spark-primary", "spark-secondary"]
            if sparkKeys.contains(key) { return "Spark · \(period ?? L("quota.label.quota"))" }
            let standardKeys = ["primary", "secondary", "codex-primary", "codex-secondary", "default-primary", "default-secondary"]
            if standardKeys.contains(key) { return period ?? L("quota.label.quota") }
            return period.map { "\(L("quota.label.extra")) · \($0)" } ?? L("quota.label.extra")
        }
        if providerId == "factory" {
            // The standard pool and the `core` overage pool repeat the same
            // periods; prefix both so every row says which pool it belongs to.
            if key == "primary" || key == "secondary" || key == "tertiary" {
                let name = key == "tertiary" ? L("quota.period.monthly") : (period ?? L("quota.label.quota"))
                return "\(L("quota.pool.standard")) · \(name)"
            }
            if key == "core-5h" || key == "core-7d" {
                return "Core · \(period ?? L("quota.label.quota"))"
            }
            if key == "core-monthly" { return "Core · \(L("quota.period.monthly"))" }
            if key == "compute" { return L("quota.label.managedComputers") }
        }
        if providerId == "amp" {
            // Amp's API folds free credit into its headline balance; the
            // reader splits them, so name the purchased part precisely.
            if key == "balance" { return L("quota.label.topUpBalance") }
        }
        if providerId == "grok" {
            // The bot channel names each model pool after the `modelName` the
            // web client queries; pool names are product labels, not copy.
            if key == "bot-auto" { return period.map { "Auto · \($0)" } ?? "Auto" }
            if key == "bot-fast" { return period.map { "Fast · \($0)" } ?? "Fast" }
            if key == "bot-expert" { return period.map { "Expert · \($0)" } ?? "Expert" }
            if key == "bot-heavy" { return period.map { "Heavy · \($0)" } ?? "Heavy" }
        }
        if ["cost-spend", "spend", "monthly-spend"].contains(quotaKey.lowercased()) && ["vercel", "cloudflare", "replit", "github-actions"].contains(providerId) {
            let scopeKey = "billing.metric." + providerId
            return L(scopeKey)
        }
        let semantic: String? = switch key {
        case "balance", "credits", "credit-balance": unit == .credits ? L("quota.label.availableCredits") : L("quota.label.availableBalance")
        case "free-balance": L("quota.label.freeToday")
        case "cost-spend", "spend", "monthly-spend": L("quota.label.currentSpend")
        case "cost-budget", "cost": L("quota.label.budgetRemaining")
        case "requests", "request-limit": L("quota.label.requestQuota")
        case "tokens", "token-limit": L("quota.label.tokenQuota")
        case "premium", "premium-requests": L("quota.label.premiumRequests")
        case "mcp": L("quota.label.mcpQuota")
        case "opus", "seven_day_opus": "Opus"
        case "sonnet", "seven_day_sonnet": "Sonnet"
        default: nil
        }
        if let semantic { return period.map { "\(semantic) · \($0)" } ?? semantic }
        if let period { return period }
        return switch unit {
        case .money: L("quota.label.availableBalance")
        case .credits: L("quota.label.availableCredits")
        case .tokens: L("quota.label.tokenQuota")
        case .requests: L("quota.label.requestQuota")
        case .percent: L("quota.label.quota")
        }
    }

    /// A past deadline is not proof the provider has replenished the allowance.
    /// Compact drops the spelled-out "Next deadline … at HH:mm" to a bare date
    /// for tight single-line surfaces.
    func resetDescription(now: Date = Date(), compact: Bool = false) -> String? {
        guard let value = window.resetsAt else {
            return isResetCardWindow ? L("quota.reset.noTime") : nil
        }
        guard let date = QuotaRules.date(value) else { return nil }
        if isResetCardWindow {
            if date <= now { return L("quota.reset.cardExpired") }
            return compact
                ? L("quota.reset.cardNext", date.formatted(date: .abbreviated, time: .omitted))
                : L("quota.reset.recentDeadline", date.formatted(date: .abbreviated, time: .shortened))
        }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("quota.reset.waitingForRefresh") }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return L("quota.reset.inMinutes", minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? L("quota.reset.inHours", hours) : L("quota.reset.inHoursMinutes", hours, rest)
        }
        let days = hours / 24, rest = hours % 24
        return rest == 0 ? L("quota.reset.inDays", days) : L("quota.reset.inDaysHours", days, rest)
    }

    private static func periodLabel(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds == 7 * 86_400 { return L("quota.period.weekly") }
        if seconds == 86_400 { return L("quota.period.daily") }
        if seconds % 86_400 == 0 { return L("quota.period.days", seconds / 86_400) }
        if seconds % 3_600 == 0 { return L("quota.period.hours", seconds / 3_600) }
        if seconds % 60 == 0 { return L("quota.period.minutes", seconds / 60) }
        return nil
    }
}
