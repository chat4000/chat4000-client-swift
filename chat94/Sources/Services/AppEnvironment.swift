import CryptoKit
import Foundation

struct AppEnvironment {
    enum Kind: String {
        case debug
        case production
    }

    let kind: Kind
    let relayURL: String
    let storageNamespace: String
    let allowInvalidRelayCertificates: Bool

    static let productionRelayURL = RelayProtocol.defaultRelayURL

    static var current: AppEnvironment {
        #if DEBUG
        let kind: Kind = .debug
        #else
        let kind: Kind = .production
        #endif

        return AppEnvironment(
            kind: kind,
            relayURL: productionRelayURL,
            storageNamespace: namespace(prefix: "production", relayURL: productionRelayURL),
            allowInvalidRelayCertificates: false
        )
    }

    private static func namespace(prefix: String, relayURL: String) -> String {
        let digest = SHA256.hash(data: Data(relayURL.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(suffix)"
    }
}
