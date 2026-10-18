import CryptoKit
import Darwin
import Foundation

#if os(macOS)
/// Read-only access to the ZCode desktop app's local credential store.
/// This login is its own account; it is never joined to a GLM API-key account.
/// It never writes, refreshes, or modifies the ZCode login.
enum ZCodeCredentialReader {
    static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/v2/credentials.json")
    }

    struct Tokens {
        let zcodeJWT: String
        let codingPlanToken: String
        let accountID: String
        let region: String
    }

    /// Read the active login and require its profile ID to match the JWT ID.
    static func login(fileURL: URL = credentialsFile, secret: String? = nil) -> Tokens? {
        guard let data = try? readPrivateStore(fileURL),
              let tokens = tokens(from: data, secret: secret) else { return nil }
        return tokens
    }

    /// Only the active platform's token and profile can identify this account.
    static func tokens(from data: Data, secret: String? = nil) -> Tokens? {
        let credentialSecret = secret ?? Self.credentialSecret
        guard let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = decrypt(store["oauth:active_provider"], secret: credentialSecret),
              active == "zai" || active == "bigmodel",
              let zcodeJWT = decrypt(store["zcodejwttoken"], secret: credentialSecret),
              let codingPlanToken = decrypt(
                store["oauth:\(active):access_token"], secret: credentialSecret),
              let userInfo = decrypt(store["oauth:\(active):user_info"], secret: credentialSecret),
              let info = try? JSONSerialization.jsonObject(with: Data(userInfo.utf8)) as? [String: Any],
              let accountID = info["id"] as? String, !accountID.isEmpty, accountID.utf8.count <= 256,
              let jwtUserID = jwtUserID(zcodeJWT), jwtUserID == accountID
        else { return nil }
        return Tokens(zcodeJWT: zcodeJWT, codingPlanToken: codingPlanToken,
                      accountID: accountID, region: active)
    }

    private static func jwtUserID(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[1].utf8.count <= 16_384,
              let payload = base64url(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return claims["user_id"] as? String
    }

    /// ZCode persists each value either as plaintext or as
    /// `enc:v1:<iv>.<tag>.<ciphertext>` (base64url) under AES-256-GCM keyed
    /// with SHA-256 of `zcode-credential-fallback:<platform>:<home>:<user>`.
    /// If the desktop app was launched with ZCODE_CREDENTIAL_SECRET the
    /// machine-derived key will not match and decryption fails — a silent skip.
    static func decrypt(_ value: Any?, secret: String) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        let prefix = "enc:v1:"
        guard value.hasPrefix(prefix) else { return sanitized(value) }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = base64url(parts[0]), iv.count == 12,
              let tag = base64url(parts[1]), tag.count == 16,
              let ciphertext = base64url(parts[2]), !ciphertext.isEmpty,
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        else { return nil }
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let plain = try? AES.GCM.open(box, using: key),
              let decoded = String(data: plain, encoding: .utf8) else { return nil }
        return sanitized(decoded)
    }

    private static func sanitized(_ value: String) -> String? {
        value.utf8.count <= 16_384 && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            ? value : nil
    }

    private static func base64url(_ raw: Substring) -> Data? {
        var encoded = String(raw).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private static var credentialSecret: String {
        "zcode-credential-fallback:darwin:\(FileManager.default.homeDirectoryForCurrentUser.path):\(NSUserName())"
    }

    /// Same hardened read as the Codex login: symlinks refused, uid-owned,
    /// owner-only mode, size-capped. Errors only feed the silent-skip path.
    private enum StoreReadError: Error { case unavailable, denied, outputLimit }

    private static func readPrivateStore(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ENOENT ? StoreReadError.unavailable : StoreReadError.denied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 131_072 else { throw StoreReadError.denied }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: 131_073), data.count <= 131_072 else {
            throw StoreReadError.outputLimit
        }
        return data
    }
}
#else
/// The ZCode desktop app only runs on macOS.
enum ZCodeCredentialReader {
    struct Tokens { let zcodeJWT: String; let codingPlanToken: String; let accountID: String; let region: String }
    static func login() -> Tokens? { nil }
}
#endif
