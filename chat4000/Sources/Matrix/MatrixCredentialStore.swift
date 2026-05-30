import Foundation
import MatrixRustSDK

/// File-based persistence of the Matrix `Session` (access/refresh tokens, device
/// id, homeserver) plus the random passphrase that encrypts the SDK's on-disk
/// store. Mirrors v1's `KeychainService` storage strategy — JSON in Application
/// Support, namespaced per environment. Replaces `GroupConfig` for v2.
enum MatrixCredentialStore {
    /// Codable mirror of the SDK's `Session` (the SDK type isn't `Codable`),
    /// plus our store passphrase.
    struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var oauthData: String?
        /// Random passphrase encrypting the SDK's SQLite store. Generated once on
        /// first pair and reused on every relaunch.
        var storePassphrase: String

        init(session: Session, storePassphrase: String) {
            self.accessToken = session.accessToken
            self.refreshToken = session.refreshToken
            self.userId = session.userId
            self.deviceId = session.deviceId
            self.homeserverUrl = session.homeserverUrl
            self.oauthData = session.oauthData
            self.storePassphrase = storePassphrase
        }

        var session: Session {
            Session(
                accessToken: accessToken,
                refreshToken: refreshToken,
                userId: userId,
                deviceId: deviceId,
                homeserverUrl: homeserverUrl,
                oauthData: oauthData,
                slidingSyncVersion: .native
            )
        }
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
        AppLog.log("💾 Matrix session saved for \(stored.userId)")
    }

    static func load() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.log("💾 Matrix session deleted")
    }

    /// Fresh 32-byte base64 store passphrase.
    static func newStorePassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

/// Bridges SDK token-refresh persistence to our file store. The SDK calls
/// `saveSessionInKeychain` whenever it rotates the access/refresh tokens; we
/// merge the rotated tokens back into the stored record (keeping the passphrase).
final class MatrixSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let stored = MatrixCredentialStore.load(), stored.userId == userId else {
            throw MatrixError.noStoredSession
        }
        return stored.session
    }

    func saveSessionInKeychain(session: Session) {
        if var existing = MatrixCredentialStore.load() {
            existing.accessToken = session.accessToken
            existing.refreshToken = session.refreshToken
            existing.oauthData = session.oauthData
            try? MatrixCredentialStore.save(existing)
        } else {
            // No record yet — shouldn't happen post-pairing, but persist with a
            // fresh passphrase rather than drop the rotated token.
            try? MatrixCredentialStore.save(
                .init(session: session, storePassphrase: MatrixCredentialStore.newStorePassphrase())
            )
        }
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
