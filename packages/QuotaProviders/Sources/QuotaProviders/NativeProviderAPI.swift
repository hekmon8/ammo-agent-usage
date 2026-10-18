import Foundation

/// Routes a stored credential to the matching self-developed API client.
enum NativeProviderAPI {
    static func fetch(providerID: String, credential: NativeProviderCredential) async throws -> NativeUsage {
        switch providerID {
        case "cloudflare": return try await CloudflareUsageReader.fetch(credential)
        case "replit": return try await ReplitUsageReader.fetch(credential)
        case "fal": return try await FalUsageReader.fetch(credential)
        case "vercel": return try await VercelUsageReader.fetch(credential)
        case "amp": return try await AmpUsageReader.fetch(credential)
        case "openrouter": return try await OpenRouterUsageReader.fetch(credential)
        case "copilot": return try await CopilotUsageReader.fetch(credential)
        case "github-actions": return try await GitHubBillingReader.fetch(credential)
        case "factory": return try await FactoryUsageReader.fetch(credential)
        case "manus": return try await ManusUsageReader.fetch(credential)
        case "zai": return try await ZaiUsageReader.fetch(credential)
        case "grok":
            return credential.kind == .cookie
                ? try await GrokBotUsageReader.fetch(credential)
                : try await GrokUsageReader.fetch(credential)
        case "deepseek": return try await DeepSeekUsageReader.fetch(credential)
        case "opencodego": return try await OpenCodeGoUsageReader.fetch(credential)
        case "antigravity": return try await AntigravityUsageReader.fetch(credential)
        case "claude": return try await ClaudeUsageReader.fetch(credential)
        case "workbuddy": return try await WorkBuddyUsageReader.fetch(credential)
        default: throw ProviderFailure.unsupported
        }
    }
}
