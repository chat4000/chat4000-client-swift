import Foundation

/// File-based persistence of the device's gateway credentials (what
/// `/pair/redeem` returns, protocol C.2) plus the passphrase that encrypts the
/// standalone crypto store at rest. No SDK `Session` type anymore — v2 talks the
/// gateway frame protocol directly. JSON in Application Support, namespaced per
/// environment.
enum MatrixCredentialStore {
    struct Stored: Codable {
        var accessToken: String
        var userId: String
        var deviceId: String
        /// The WS gateway URL the device connects to (`gateway_url` from redeem).
        var gatewayURL: String
        /// Random passphrase encrypting the OlmMachine SQLite store. Generated
        /// once on first pair, reused on every relaunch.
        var storePassphrase: String
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("matrix-session.json")
    }

    static func save(_ stored: Stored) throws {
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: [.atomic])
        AppLog.log("💾 Matrix credentials saved for \(stored.userId)")
    }

    static func load() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.log("💾 Matrix credentials deleted")
    }

    /// Fresh 32-byte base64 store passphrase.
    static func newStorePassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

enum MatrixError: LocalizedError {
    case noStoredSession
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noStoredSession: "No stored Matrix session."
        case .pairingFailed(let m): "Pairing failed: \(m)"
        }
    }
}
