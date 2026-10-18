import Foundation
import CryptoKit

/// RFC 9180 HPKE via CryptoKit, with the already-pinned Ed25519 source signing the wrap.
public enum SnapshotKeyWrap {
    private struct Wrap: Codable {
        let version: Int
        let suite, context, encapsulatedKey, ciphertext, signature: String
    }
    private static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
    private static func info(_ context: String) throws -> Data {
        guard context.range(of: "^[A-Za-z0-9_-]{1,80}([|][A-Za-z0-9_-]{1,80}){4}$", options: .regularExpression) != nil else { throw SyncError.invalidKey }
        return Data("QI-WRAP|1|\(context)".utf8)
    }
    public static func seal(key: SymmetricKey, recipient: Curve25519.KeyAgreement.PublicKey, context: String, signer: Curve25519.Signing.PrivateKey) throws -> String {
        guard key.bitCount == 256 else { throw SyncError.invalidKey }
        let aad = try info(context)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: aad)
        let ciphertext = try sender.seal(key.withUnsafeBytes { Data($0) }, authenticating: aad)
        let signature = try signer.signature(for: aad + Data([10]) + sender.encapsulatedKey + ciphertext)
        let wrap = Wrap(version: 1, suite: "X25519-HKDF-SHA256-AES256GCM", context: context, encapsulatedKey: Base64URL.encode(sender.encapsulatedKey), ciphertext: Base64URL.encode(ciphertext), signature: Base64URL.encode(signature))
        return Base64URL.encode(try JSONEncoder().encode(wrap))
    }
    public static func open(_ string: String, recipient: Curve25519.KeyAgreement.PrivateKey, context: String, sourceKey: Curve25519.Signing.PublicKey) throws -> SymmetricKey {
        guard string.count <= 4096 else { throw SyncError.invalidKey }
        let data = try Base64URL.decode(string)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == Set(["version","suite","context","encapsulatedKey","ciphertext","signature"]) else { throw SyncError.invalidKey }
        let wrap = try JSONDecoder().decode(Wrap.self, from: data)
        guard wrap.version == 1, wrap.suite == "X25519-HKDF-SHA256-AES256GCM", wrap.context == context else { throw SyncError.untrustedSource }
        let aad = try info(context), encapsulated = try Base64URL.decode(wrap.encapsulatedKey), ciphertext = try Base64URL.decode(wrap.ciphertext)
        guard encapsulated.count == 32, ciphertext.count == 48,
              try sourceKey.isValidSignature(Base64URL.decode(wrap.signature), for: aad + Data([10]) + encapsulated + ciphertext) else { throw SyncError.untrustedSource }
        var receiver = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: aad, encapsulatedKey: encapsulated)
        let bytes = try receiver.open(ciphertext, authenticating: aad)
        guard bytes.count == 32 else { throw SyncError.invalidKey }
        return SymmetricKey(data: bytes)
    }
}
