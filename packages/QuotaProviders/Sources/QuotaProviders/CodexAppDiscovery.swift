import Foundation
import Security

/// Locates the native Codex CLI that ships inside OpenAI's desktop apps and
/// verifies a selected executable before the app ever launches it. Never runs
/// login shells and never imports ambient credentials.
public enum CodexAppDiscovery {
    /// The CLI lives in both apps' resource bundles; user-scoped installs are
    /// shadowed in favor of the home directory, mirroring LaunchServices order.
    public static func bundledCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: URL = URL(fileURLWithPath: "/Applications")) -> [URL]
    {
        [home.appendingPathComponent("Applications"), applications].flatMap { directory in
            ["ChatGPT.app", "Codex.app"].map { directory.appendingPathComponent($0 + "/Contents/Resources/codex") }
        }
    }

    public static func installedApp() -> URL? {
        bundledCandidates().first { isNativeMachO($0) && isOpenAISigned($0) }
    }

    /// Accepts only executables whose enclosing app bundle carries OpenAI's
    /// Developer ID signature; renamed or modified copies fail closed.
    public static func isOpenAISigned(_ executable: URL) -> Bool {
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and (identifier \"com.openai.codex\" or identifier \"com.openai.chat\")"
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
    }

    /// Only a native Mach-O binary qualifies; a script or Node wrapper must
    /// never be approved as a connection executable.
    public static func isNativeMachO(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]]
            .contains(Array(bytes).map(Int.init))
    }
}
