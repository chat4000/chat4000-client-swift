import CryptoKit
import Foundation

struct GroupConfig: Codable, Equatable {
    /// Base64-encoded 32-byte group key (for JSON persistence).
    var groupKeyBase64: String

    /// Optional relay URL override. Nil = use default.
    var relayURLOverride: String?

    // MARK: - Computed

    var groupKey: Data? {
        Data(base64Encoded: groupKeyBase64)
    }

    var groupId: String? {
        guard let key = groupKey, key.count == 32 else { return nil }
        return RelayCrypto.deriveGroupId(from: key)
    }

    var relayURL: URL {
        URL(string: RelayProtocol.defaultRelayURL)!
    }

    var isValid: Bool {
        guard let key = groupKey else { return false }
        return key.count == 32
    }

    // MARK: - Init helpers

    /// Create from raw 32-byte key data.
    init(groupKey: Data, relayURLOverride: String? = nil) {
        self.groupKeyBase64 = groupKey.base64EncodedString()
        self.relayURLOverride = relayURLOverride
    }

    /// Create from base64url-encoded key (from QR code).
    init?(base64URLKey: String, relayURLOverride: String? = nil) {
        guard let data = RelayCrypto.groupKeyFromBase64URL(base64URLKey) else { return nil }
        self.groupKeyBase64 = data.base64EncodedString()
        self.relayURLOverride = relayURLOverride
    }

    /// Create from standard base64-encoded key.
    init?(base64Key: String, relayURLOverride: String? = nil) {
        guard let data = Data(base64Encoded: base64Key), data.count == 32 else { return nil }
        self.groupKeyBase64 = data.base64EncodedString()
        self.relayURLOverride = relayURLOverride
    }

    /// Parse from `chat4000://pair/<base64url-key>` URI.
    static func fromGroupURI(_ uri: String) -> GroupConfig? {
        guard let key = RelayCrypto.parseGroupURI(uri) else { return nil }
        return GroupConfig(groupKey: key)
    }

    /// Accepts a full group URI, base64url, or standard base64 group key.
    static func parse(_ string: String, relayURLOverride: String? = nil) -> GroupConfig? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let config = GroupConfig.fromGroupURI(trimmed) {
            return config
        }
        if let config = GroupConfig(base64URLKey: trimmed, relayURLOverride: relayURLOverride) {
            return config
        }
        return GroupConfig(base64Key: trimmed, relayURLOverride: relayURLOverride)
    }

    /// Build `chat4000://pair/<base64url-key>` URI for QR code.
    var groupURI: String? {
        guard let key = groupKey else { return nil }
        return RelayCrypto.buildGroupURI(groupKey: key)
    }
}
