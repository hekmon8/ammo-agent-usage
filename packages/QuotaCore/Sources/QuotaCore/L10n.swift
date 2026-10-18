import Foundation

/// Languages Ammo ships. `system` follows the user's preferred
/// localizations; the explicit cases pin every surface to one language.
public enum QuotaLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Picker label. Language names stay endonyms so they remain readable
    /// before the switch happens.
    public var displayName: String {
        switch self {
        case .system: L10n.text("language.option.system")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// Central lookup for every user-facing string. Values live in
/// `Resources/<lang>.lproj/Localizable.strings` inside the QuotaCore bundle,
/// so the Mac app, phone app, widgets and CLI share one table.
///
/// Localized values must never be cached in stored `let` properties or static
/// constants: they would capture whichever language was active on first access.
/// Compute them at render time instead.
public enum L10n {
    /// Posted on the main thread after the effective language changes so views
    /// can rebuild.
    public static let languageDidChange = Notification.Name("quota.island.language-did-change")
    static let developmentLocalization = "zh-Hans"
    static let storageKey = "quota.island.language"

    private static let store = Store()

    /// Register extra defaults suites (the App Group) so the phone app and the
    /// widget extension agree on one override across process boundaries.
    public static func install(additionalDefaults suite: UserDefaults) {
        store.install(suite: suite)
    }

    /// The setting the picker reflects, exactly as persisted (`.system` included).
    public static var currentSetting: QuotaLanguage {
        store.currentSetting
    }

    /// The language table lookups resolve against right now.
    public static var effectiveLanguageCode: String {
        store.effectiveLanguageCode
    }

    /// Monotonic counter bumped on every language change; SwiftUI roots can
    /// key their identity on it to rebuild with fresh strings.
    public static var revision: Int {
        store.revision
    }

    public static func setLanguage(_ language: QuotaLanguage) {
        store.set(language)
        if Thread.isMainThread {
            NotificationCenter.default.post(name: languageDidChange, object: nil)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: L10n.languageDidChange, object: nil) }
        }
    }

    /// Reset to following the system language.
    public static func resetLanguage() { setLanguage(.system) }

    public static func text(_ key: String, _ args: CVarArg...) -> String { text(key, arguments: args) }

    public static func text(_ key: String, arguments: [CVarArg]) -> String {
        let value = store.bundle.localizedString(forKey: key, value: key, table: table(for: key))
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale.current, arguments: arguments)
    }

    /// `LocalizedStringResource` variant for APIs that require one (AppIntents,
    /// WidgetKit configuration). Resolves against the shared tables and carries
    /// the effective language at creation time.
    public static func resource(_ key: String) -> LocalizedStringResource {
        LocalizedStringResource(
            String.LocalizationValue(key),
            table: table(for: key),
            locale: Locale(identifier: effectiveLanguageCode),
            bundle: Bundle.module
        )
    }

    /// Keep feature-local copy isolated without changing any existing lookup.
    static func table(for key: String) -> String? {
        if key.hasPrefix("resetReminder.") { return "ResetReminder" }
        return key.hasPrefix("tokenUsage.") ? "TokenUsage" : nil
    }

    /// All mutable lookup state behind one re-entrant lock; the shared
    /// instance is immutable, which keeps Swift 6 strict concurrency satisfied.
    private final class Store: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var additionalDefaults: [UserDefaults] = []
        private var cachedBundle: Bundle?
        private var cachedLanguage: String?
        private var revisionValue = 0

        func install(suite: UserDefaults) {
            lock.lock(); defer { lock.unlock() }
            guard !additionalDefaults.contains(where: { $0 === suite }) else { return }
            additionalDefaults.append(suite)
            cachedBundle = nil
            cachedLanguage = nil
        }

        var currentSetting: QuotaLanguage {
            lock.lock(); defer { lock.unlock() }
            guard let raw = UserDefaults.standard.string(forKey: L10n.storageKey),
                  let language = QuotaLanguage(rawValue: raw) else { return .system }
            return language
        }

        var effectiveLanguageCode: String {
            lock.lock(); defer { lock.unlock() }
            for defaults in [UserDefaults.standard] + additionalDefaults {
                guard let raw = defaults.string(forKey: L10n.storageKey),
                      let language = QuotaLanguage(rawValue: raw), language != .system else { continue }
                return language.rawValue
            }
            return Bundle.preferredLocalizations(from: ["zh-Hans", "en"]).first ?? L10n.developmentLocalization
        }

        var revision: Int {
            lock.lock(); defer { lock.unlock() }
            return revisionValue
        }

        func set(_ language: QuotaLanguage) {
            lock.lock()
            UserDefaults.standard.set(language.rawValue, forKey: L10n.storageKey)
            for defaults in additionalDefaults { defaults.set(language.rawValue, forKey: L10n.storageKey) }
            cachedBundle = nil
            cachedLanguage = nil
            revisionValue += 1
            lock.unlock()
        }

        var bundle: Bundle {
            lock.lock(); defer { lock.unlock() }
            let language = effectiveLanguageCode
            if let cachedBundle, let cachedLanguage, cachedLanguage == language { return cachedBundle }
            let resource = Bundle.module
            // SwiftPM may lowercase lproj directory names (zh-Hans → zh-hans),
            // so match the localization case-insensitively instead of by exact path.
            let resolved = Self.lproj(in: resource, language: language) ?? resource
            cachedBundle = resolved
            cachedLanguage = language
            return resolved
        }

        private static func lproj(in bundle: Bundle, language: String) -> Bundle? {
            guard let resourceURL = bundle.resourceURL,
                  let contents = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil) else { return nil }
            return contents.first { $0.pathExtension == "lproj" && $0.deletingPathExtension().lastPathComponent.lowercased() == language.lowercased() }
                .flatMap { Bundle(url: $0) }
        }
    }
}

/// Look up a localized string: `L("sync.icloud.title")` or
/// `L("reset.in.minutes", 12)`. The companion tables live in
/// `packages/QuotaCore/Sources/QuotaCore/Resources`.
public func L(_ key: String, _ args: CVarArg...) -> String { L10n.text(key, arguments: args) }

/// A user-facing status line stored as its key plus format arguments instead of
/// the rendered string, so a language switch re-renders it in the new language.
/// Model code publishes these; views read `text` at render time. Rendered `L()`
/// values must never be kept in stored properties — this is the sanctioned way
/// to hold a message that outlives the event that produced it.
public struct LocalizedStatus: Sendable {
    public let key: String
    public let arguments: [any CVarArg & Sendable]

    public init(_ key: String, _ arguments: any CVarArg & Sendable...) {
        self.key = key
        self.arguments = arguments
    }

    /// Resolves against the language that is active right now.
    public var text: String { L10n.text(key, arguments: arguments) }

    public var isEmpty: Bool { key.isEmpty }

    public static let empty = LocalizedStatus("")
}
