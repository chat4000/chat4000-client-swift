import CryptoKit
import Foundation
import Sodium

struct PairingInvite: Equatable {
    let code: String
}

// MARK: - Relay Crypto
//
enum RelayCrypto {
    // MARK: - Group ID

    /// `lowercase_hex(SHA-256(group_key_bytes))`
    static func deriveGroupId(from groupKey: Data) -> String {
        SHA256.hash(data: groupKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Generate a random 32-byte group key.
    static func generateGroupKey() -> Data {
        randomData(length: 32)
    }

    static func randomData(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    // Protocol-defined ambiguity-safe alphabet (docs/protocol.md): excludes
    // 0, 1, 5 and the visually ambiguous letters I, L, O, Q, S.
    static let pairingCodeAlphabet = Array("ABCDEFGHJKMNPRTUVWXYZ2346789")

    static func generatePairingCode() -> String {
        var chars: [Character] = []
        chars.reserveCapacity(8)

        while chars.count < 8 {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { continue }
            chars.append(pairingCodeAlphabet[Int(byte) % pairingCodeAlphabet.count])
        }

        let code = String(chars)
        return "\(code.prefix(4))-\(code.suffix(4))"
    }

    static func normalizePairingCode(_ code: String) -> String {
        code.uppercased().filter { pairingCodeAlphabet.contains($0) }
    }

    static func derivePairingRoomId(from code: String) -> String {
        let normalized = normalizePairingCode(code)
        let input = Data("pairing-v1:\(normalized)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    static func derivePairProof(code: String, initiatorSalt: Data, joinerPublicKey: Data, label: String) -> String {
        var data = Data(normalizePairingCode(code).utf8)
        data.append(0)
        data.append(initiatorSalt)
        data.append(0)
        data.append(joinerPublicKey)
        data.append(0)
        data.append(Data(label.utf8))
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func generateJoinerPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func publicKeyData(from privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data {
        privateKey.publicKey.rawRepresentation
    }

    private static let currentPairWrapLabel = "chat4000-pair-wrap-v1"
    private static let legacyPairWrapLabels = [
        "clawconnect-pair-wrap-v1"
    ]

    static func wrapGroupKey(_ groupKey: Data, to joinerPublicKeyData: Data) -> WrappedGroupKey? {
        let senderPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let joinerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: joinerPublicKeyData),
              let wrapKey = makeWrappingKey(
                privateKey: senderPrivateKey,
                publicKey: joinerPublicKey,
                label: currentPairWrapLabel
              ),
              let encrypted = encrypt(plaintext: groupKey, key: wrapKey)
        else {
            return nil
        }

        return WrappedGroupKey(
            ephemeralPub: senderPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        )
    }

    static func unwrapGroupKey(
        _ wrappedKey: WrappedGroupKey,
        joinerPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) -> Data? {
        guard let initiatorPublicKeyData = Data(base64Encoded: wrappedKey.ephemeralPub),
              let initiatorPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorPublicKeyData)
        else {
            return nil
        }

        let labels = [currentPairWrapLabel] + legacyPairWrapLabels
        for label in labels {
            guard let wrapKey = makeWrappingKey(
                privateKey: joinerPrivateKey,
                publicKey: initiatorPublicKey,
                label: label
            ) else {
                continue
            }

            if let plaintext = decrypt(
                nonceBase64: wrappedKey.nonce,
                ciphertextBase64: wrappedKey.ciphertext,
                key: wrapKey
            ) {
                return plaintext
            }
        }

        return nil
    }

    private static func makeWrappingKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        label: String
    ) -> Data? {
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            return nil
        }

        var material = secret.withUnsafeBytes { Data($0) }
        material.append(Data(label.utf8))
        return Data(SHA256.hash(data: material))
    }

    // MARK: - XChaCha20-Poly1305

    /// Encrypt plaintext → (nonce_base64, ciphertext_base64).
    static func encrypt(plaintext: Data, key: Data) -> (nonce: String, ciphertext: String)? {
        guard key.count == 32 else { return nil }

        let sodium = Sodium()
        let keyBytes = [UInt8](key)
        let messageBytes = [UInt8](plaintext)
        guard let (ciphertext, nonce) = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: messageBytes,
            secretKey: keyBytes,
            additionalData: nil
        ) else {
            return nil
        }

        guard nonce.count == 24 else { return nil }

        return (
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: Data(ciphertext).base64EncodedString()
        )
    }

    /// Decrypt ciphertext_base64 with nonce_base64 → plaintext.
    static func decrypt(nonceBase64: String, ciphertextBase64: String, key: Data) -> Data? {
        guard key.count == 32,
              let nonce = Data(base64Encoded: nonceBase64),
              nonce.count == 24,
              let ciphertext = Data(base64Encoded: ciphertextBase64)
        else {
            return nil
        }

        let sodium = Sodium()
        guard let plaintext = sodium.aead.xchacha20poly1305ietf.decrypt(
            authenticatedCipherText: [UInt8](ciphertext),
            secretKey: [UInt8](key),
            nonce: [UInt8](nonce),
            additionalData: nil
        ) else {
            return nil
        }

        return Data(plaintext)
    }

    // MARK: - QR / URI helpers (work now — no crypto needed)

    static func groupKeyToBase64URL(_ key: Data) -> String {
        key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func groupKeyFromBase64URL(_ string: String) -> Data? {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: b64), data.count == 32 else { return nil }
        return data
    }

    static func parseGroupURI(_ uri: String) -> Data? {
        let prefix = "chat4000://pair/"
        guard uri.hasPrefix(prefix) else { return nil }
        return groupKeyFromBase64URL(String(uri.dropFirst(prefix.count)))
    }

    static func parsePairingURI(_ uri: String) -> PairingInvite? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "chat4000",
              components.host == "pair"
        else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        guard let rawCode = queryItems.first(where: { $0.name == "code" })?.value else {
            return nil
        }

        let normalizedCode = normalizePairingCode(rawCode)
        guard normalizedCode.count == 8 else { return nil }

        return PairingInvite(
            code: normalizedCode
        )
    }

    static func buildGroupURI(groupKey: Data) -> String {
        "chat4000://pair/\(groupKeyToBase64URL(groupKey))"
    }
}
