import Foundation
import QuotaCore

public struct NativeProviderDescriptor: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String

    public var connectionHelp: String {
        switch id {
        case "cloudflare": L("catalog.help.cloudflare")
        case "replit": L("catalog.help.replit")
        case "fal": L("catalog.help.fal")
        case "vercel": L("catalog.help.vercel")
        case "opencodego": L("catalog.help.opencodego")
        case "copilot": L("catalog.help.copilot")
        case "github-actions": L("catalog.help.github-actions")
        case "factory": L("catalog.help.factory")
        case "manus": L("catalog.help.manus")
        case "zai": L("catalog.help.zai")
        case "zcode": L("catalog.help.zcode")
        case "amp": L("catalog.help.amp")
        case "openrouter": L("catalog.help.openrouter")
        case "grok": L("catalog.help.grok")
        case "deepseek": L("catalog.help.deepseek")
        case "antigravity": L("catalog.help.antigravity")
        case "claude": L("catalog.help.claude")
        case "workbuddy": L("catalog.help.workbuddy")
        default: L("catalog.help.default")
        }
    }

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The provider surface exposed by Ammo.
///
/// Codex uses an isolated app-server profile. The other entries are
/// self-developed API clients: an explicitly entered credential is stored in
/// the app-owned Keychain vault and each fetch calls the provider's official
/// endpoints directly.
public enum NativeProviderCatalog {
    public static let all: [NativeProviderDescriptor] = [
        .init(id: "codex", displayName: "Codex"),
        .init(id: "claude", displayName: "Claude"),
        .init(id: "workbuddy", displayName: "WorkBuddy"),
        .init(id: "opencodego", displayName: "OpenCode Go"),
        .init(id: "copilot", displayName: "GitHub Copilot"),
        .init(id: "github-actions", displayName: "GitHub Actions"),
        .init(id: "factory", displayName: "Droid"),
        .init(id: "manus", displayName: "Manus"),
        .init(id: "zai", displayName: "z.ai / GLM"),
        .init(id: "zcode", displayName: "ZCode"),
        .init(id: "amp", displayName: "Amp"),
        .init(id: "openrouter", displayName: "OpenRouter"),
        .init(id: "fal", displayName: "fal"),
        .init(id: "cloudflare", displayName: "Cloudflare"),
        .init(id: "replit", displayName: "Replit Enterprise"),
        .init(id: "vercel", displayName: "Vercel"),
        .init(id: "grok", displayName: "Grok"),
        .init(id: "deepseek", displayName: "DeepSeek"),
        .init(id: "antigravity", displayName: "Antigravity"),
    ]

    public static let apiProviderIDs = Set(all.lazy.map(\.id).filter { $0 != "codex" && $0 != "zcode" })

    public static func descriptor(for providerID: String) -> NativeProviderDescriptor? {
        all.first { $0.id == providerID }
    }

    public static func validateAPI(providerID raw: String) throws -> NativeProviderDescriptor {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiProviderIDs.contains(id), let descriptor = descriptor(for: id) else {
            throw ProviderFailure.unsupported
        }
        return descriptor
    }

    /// Credential kinds each provider's API accepts, in display order.
    public static func supportedCredentialKinds(providerID: String) -> Set<NativeProviderCredential.Kind> {
        switch providerID {
        case "amp":
            return [.apiKey]
        case "openrouter", "copilot", "github-actions", "factory", "zai", "fal", "vercel", "cloudflare", "replit":
            return [.apiKey]
        case "deepseek":
            return [.apiKey, .cookie]
        case "grok":
            return [.apiKey, .cookie]
        case "manus":
            return [.cookie]
        case "opencodego":
            return [.apiKey, .cookie]
        case "antigravity", "claude":
            return [.oauth]
        case "workbuddy":
            return [.apiKey]
        default:
            return []
        }
    }
}
