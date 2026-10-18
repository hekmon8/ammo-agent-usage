import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Attributed provider marks and original letter placeholders bundled under
/// `Resources/ProviderMarks`; unknown provider IDs use a code-drawn lettermark.
@MainActor
public struct ProviderBrandAsset: View {
    private static var images: [String: Image] = [:]
    private static var missing: Set<String> = []
    private let providerID: String
    public init(providerID: String) { self.providerID = providerID }

    public var body: some View {
        if let mark = Self.nativeImage(for: providerID) {
            mark
                .renderingMode(.template).resizable().scaledToFit()
                .accessibilityHidden(true)
        } else {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                Text(Self.initial(for: providerID))
                    .font(.system(size: max(side * 0.62, 1), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .accessibilityHidden(true)
        }
    }

    static func nativeImage(for providerID: String) -> Image? {
        let name = resourceName(for: providerID)
        if let image = images[name] { return image }
        if missing.contains(name) { return nil }
        guard let url = Bundle.module.url(forResource: "ProviderIcon-" + name, withExtension: "png") else {
            missing.insert(name)
            return nil
        }
        #if os(macOS)
        guard let native = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: native)
        #else
        guard let native = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: native)
        #endif
        images[name] = image
        return image
    }

    /// Matches the catalog's normalized IDs and keeps historical resource aliases.
    static func resourceName(for id: String) -> String {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = [
            "openai": "codex", "codex-cli": "codex", "azure-openai": "codex",
            "anthropic": "claude", "claude-code": "claude",
            "codebuddy": "workbuddy",
            "z.ai": "zai", "z-ai": "zai", "glm": "zai", "zhipu": "zai", "zhipuai": "zai",
            "google-gemini": "gemini", "github-copilot": "copilot",
            "droid": "factory", "factory-droid": "factory",
            "qwen": "alibaba", "dashscope": "alibaba",
            "alibaba-coding-plan": "alibaba", "alibaba-token-plan": "alibaba",
            "qwen-cloud": "qwencloud", "groqcloud": "groq",
            "open-code": "opencode", "opencode-go": "opencodego", "open-router": "openrouter",
            "moonshot": "kimi", "kimik2": "kimi", "kimi-k2": "kimi",
            "abacusai": "abacus", "mini-max": "minimax"
        ]
        return aliases[normalized] ?? normalized
    }

    static func initial(for id: String) -> String {
        let name = resourceName(for: id)
        let letter = name.first { $0.isLetter || $0.isNumber }
        return letter.map { String($0).uppercased() } ?? "?"
    }
}
