import Darwin
import Foundation

/// Antigravity OAuth import. A user-selected file or pasted JSON is accepted
/// once; refresh tokens are deliberately dropped, so an expired access token
/// requires re-importing instead of silent background refresh.
public enum AntigravityCredentialImport {
    /// Shape of Google's cloud-code OAuth export. Both snake_case and
    /// camelCase spellings are accepted because historical files use either.
    struct ImportedOAuth: Decodable {
        let accessTokenSnake: String?
        let accessTokenCamel: String?
        let idToken: String?
        let email: String?
        let projectIDSnake: String?
        let projectIDCamel: String?
        let expiryDateMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case idToken = "id_token"
            case email
            case projectIDSnake = "project_id"
            case projectIDCamel = "projectId"
            case expiryDateSnake = "expiry_date"
            case expiryDateCamel = "expiryDate"
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accessTokenSnake = try values.decodeIfPresent(String.self, forKey: .accessTokenSnake)
            accessTokenCamel = try values.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            idToken = try values.decodeIfPresent(String.self, forKey: .idToken)
            email = try values.decodeIfPresent(String.self, forKey: .email)
            projectIDSnake = try values.decodeIfPresent(String.self, forKey: .projectIDSnake)
            projectIDCamel = try values.decodeIfPresent(String.self, forKey: .projectIDCamel)
            if let double = try? values.decodeIfPresent(Double.self, forKey: .expiryDateSnake) {
                expiryDateMilliseconds = double
            } else if let integer = try? values.decodeIfPresent(Int64.self, forKey: .expiryDateSnake) {
                expiryDateMilliseconds = Double(integer)
            } else if let double = try? values.decodeIfPresent(Double.self, forKey: .expiryDateCamel) {
                expiryDateMilliseconds = double
            } else if let integer = try? values.decodeIfPresent(Int64.self, forKey: .expiryDateCamel) {
                expiryDateMilliseconds = Double(integer)
            } else {
                expiryDateMilliseconds = nil
            }
        }

        var accessToken: String? { accessTokenSnake ?? accessTokenCamel }
        var projectID: String? { projectIDSnake ?? projectIDCamel }
        var expiryDate: Date? { expiryDateMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    /// Canonical stored envelope: exactly what later fetches need, nothing else.
    struct StoredOAuth: Codable {
        let accessToken: String
        let projectID: String
        let idToken: String?
        let email: String?
        let expiryDateMilliseconds: Double?
    }

    /// A user-selected file is read once. Refresh/client secrets are deliberately
    /// excluded from the credential saved into the instance vault.
    public static func read(_ url: URL, now: Date = Date()) throws -> NativeProviderCredential {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProviderFailure.permissionDenied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 65_536 else {
            throw ProviderFailure.permissionDenied
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw ProviderFailure.outputLimit }
        return try credential(from: data, now: now)
    }

    public static func credential(from data: Data, now: Date = Date()) throws -> NativeProviderCredential {
        guard data.count <= 65_536,
              let input = try? JSONDecoder().decode(ImportedOAuth.self, from: data),
              let access = input.accessToken, !access.isEmpty, access.utf8.count <= 32_768,
              access.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              access.rangeOfCharacter(from: .controlCharacters) == nil,
              let project = input.projectID, !project.isEmpty, project.utf8.count <= 512,
              project.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              project.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProviderFailure.authRequired }
        if let expiry = input.expiryDate, expiry <= now { throw ProviderFailure.authRequired }
        let stored = StoredOAuth(
            accessToken: access, projectID: project, idToken: input.idToken,
            email: input.email, expiryDateMilliseconds: input.expiryDateMilliseconds)
        guard let value = try? JSONEncoder().encode(stored), let text = String(data: value, encoding: .utf8) else {
            throw ProviderFailure.parseChanged
        }
        return NativeProviderCredential(kind: .oauth, value: text)
    }

    static func storedOAuth(from credential: NativeProviderCredential) throws -> StoredOAuth {
        guard credential.kind == .oauth,
              let stored = try? JSONDecoder().decode(StoredOAuth.self, from: Data(credential.value.utf8))
        else { throw ProviderFailure.authRequired }
        return stored
    }
}
