import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end-encrypted Matrix media (protocol D.3). Blobs never cross the WS:
/// the sender AES-256-CTR-encrypts the bytes, uploads the *ciphertext* to the
/// homeserver media repo (reverse-proxied on the gateway host), and embeds the
/// decryption key/iv/hashes in an `EncryptedFile` object inside the E2EE message
/// content — so the homeserver stores an opaque blob and never sees the key.
/// Receivers download the ciphertext and decrypt locally.
///
/// The `EncryptedFile` shape follows the Matrix encrypted-attachments spec
/// (`m.encrypted` `file` object, v2): JWK A256CTR key, 16-byte IV (8 random ‖ 8
/// zero counter), unpadded-base64 SHA-256 of the ciphertext.
enum MatrixMedia {
    enum MediaError: LocalizedError {
        case crypto, upload(Int), badMxc, download(Int), hashMismatch
        var errorDescription: String? {
            switch self {
            case .crypto: "Media encryption/decryption failed"
            case .upload(let s): "Media upload failed (HTTP \(s))"
            case .badMxc: "Malformed mxc:// URI"
            case .download(let s): "Media download failed (HTTP \(s))"
            case .hashMismatch: "Downloaded media failed its SHA-256 check"
            }
        }
    }

    /// Encrypt + upload `plaintext`, returning the `EncryptedFile` object (with
    /// the `mxc://` url filled in) to embed in the message content.
    static func encryptAndUpload(
        _ plaintext: Data,
        mediaBaseURL: String,
        accessToken: String,
        filename: String
    ) async throws -> [String: Any] {
        let key = randomBytes(32)
        // 16-byte CTR IV: 8 random bytes ‖ 8 zero counter bytes (Matrix spec).
        let iv = randomBytes(8) + Data(count: 8)
        guard let ciphertext = aesCTR(plaintext, key: key, iv: iv) else { throw MediaError.crypto }
        let sha = Data(SHA256.hash(data: ciphertext))

        let mxc = try await upload(ciphertext, mediaBaseURL: mediaBaseURL, accessToken: accessToken, filename: filename)

        return [
            "v": "v2",
            "url": mxc,
            "key": [
                "kty": "oct",
                "alg": "A256CTR",
                "ext": true,
                "k": base64url(key),
                "key_ops": ["encrypt", "decrypt"],
            ],
            "iv": unpaddedBase64(iv),
            "hashes": ["sha256": unpaddedBase64(sha)],
        ]
    }

    /// Parsed `EncryptedFile` fields. `Sendable` (only `String`s) so it can cross
    /// from the main actor into the nonisolated download path without tripping
    /// Swift 6 data-race checking (a raw `[String: Any]` cannot).
    struct EncryptedFile: Sendable {
        let mxc: String
        let keyBase64url: String
        let ivBase64: String
        let sha256Base64: String?

        init?(_ file: [String: Any]) {
            guard let mxc = file["url"] as? String,
                  let keyObj = file["key"] as? [String: Any],
                  let k = keyObj["k"] as? String,
                  let iv = file["iv"] as? String
            else { return nil }
            self.mxc = mxc
            self.keyBase64url = k
            self.ivBase64 = iv
            self.sha256Base64 = (file["hashes"] as? [String: Any])?["sha256"] as? String
        }
    }

    /// Download + decrypt the blob referenced by an `EncryptedFile`.
    static func downloadAndDecrypt(
        _ file: EncryptedFile,
        mediaBaseURL: String,
        accessToken: String
    ) async throws -> Data {
        guard let key = decodeBase64url(file.keyBase64url),
              let iv = decodeUnpaddedBase64(file.ivBase64)
        else { throw MediaError.crypto }

        let ciphertext = try await download(mxc: file.mxc, mediaBaseURL: mediaBaseURL, accessToken: accessToken)

        if let expected = file.sha256Base64.flatMap(decodeUnpaddedBase64) {
            guard Data(SHA256.hash(data: ciphertext)) == expected else { throw MediaError.hashMismatch }
        }

        guard let plaintext = aesCTR(ciphertext, key: key, iv: iv) else { throw MediaError.crypto }
        return plaintext
    }

    // MARK: - HTTP (authenticated media, protocol D.3)

    private static func upload(
        _ ciphertext: Data,
        mediaBaseURL: String,
        accessToken: String,
        filename: String
    ) async throws -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? "blob"
        guard let url = URL(string: "\(mediaBaseURL)/_matrix/media/v3/upload?filename=\(encodedName)") else {
            throw MediaError.upload(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = ciphertext

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MediaError.upload(status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mxc = obj["content_uri"] as? String else { throw MediaError.upload(status) }
        return mxc
    }

    private static func download(
        mxc: String,
        mediaBaseURL: String,
        accessToken: String
    ) async throws -> Data {
        // mxc://<server>/<mediaId>
        guard mxc.hasPrefix("mxc://") else { throw MediaError.badMxc }
        let rest = mxc.dropFirst("mxc://".count)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw MediaError.badMxc }
        let server = String(parts[0]), mediaId = String(parts[1])

        guard let url = URL(string: "\(mediaBaseURL)/_matrix/client/v1/media/download/\(server)/\(mediaId)") else {
            throw MediaError.badMxc
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MediaError.download(status) }
        return data
    }

    // MARK: - AES-256-CTR (CommonCrypto)

    private static func aesCTR(_ data: Data, key: Data, iv: Data) -> Data? {
        var cryptorRef: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), // CTR is symmetric: encrypt op decrypts too
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptorRef
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count) // CTR output length == input length
        let capacity = output.count
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, data.count, outPtr.baseAddress, capacity, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - Encoding helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Unpadded standard base64 (Matrix uses unpadded base64 for iv/hashes).
    private static func unpaddedBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Unpadded base64url (JWK key `k`).
    private static func base64url(_ data: Data) -> String {
        unpaddedBase64(data)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func decodeUnpaddedBase64(_ string: String) -> Data? {
        Data(base64Encoded: padded(string))
    }

    private static func decodeBase64url(_ string: String) -> Data? {
        let standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: padded(standard))
    }

    private static func padded(_ string: String) -> String {
        let remainder = string.count % 4
        return remainder == 0 ? string : string + String(repeating: "=", count: 4 - remainder)
    }

    #if DEBUG
    /// Test hook: full crypto roundtrip in-memory (no network) — encrypt, build
    /// the `EncryptedFile` JSON, parse it back, verify the SHA-256, and decrypt.
    /// Exercises AES-CTR symmetry, the 8-random‖8-zero IV, base64url/unpadded
    /// base64, and `EncryptedFile` parsing — the bits most prone to silent bugs.
    static func cryptoRoundtripForTesting(_ plaintext: Data) -> Data? {
        let key = randomBytes(32)
        let iv = randomBytes(8) + Data(count: 8)
        guard let ciphertext = aesCTR(plaintext, key: key, iv: iv) else { return nil }
        let sha = Data(SHA256.hash(data: ciphertext))
        let fileDict: [String: Any] = [
            "url": "mxc://test.server/abc123",
            "key": ["k": base64url(key)],
            "iv": unpaddedBase64(iv),
            "hashes": ["sha256": unpaddedBase64(sha)],
        ]
        guard let parsed = EncryptedFile(fileDict),
              let recoveredKey = decodeBase64url(parsed.keyBase64url),
              let recoveredIv = decodeUnpaddedBase64(parsed.ivBase64),
              let expected = parsed.sha256Base64.flatMap(decodeUnpaddedBase64),
              Data(SHA256.hash(data: ciphertext)) == expected
        else { return nil }
        return aesCTR(ciphertext, key: recoveredKey, iv: recoveredIv)
    }
    #endif
}
