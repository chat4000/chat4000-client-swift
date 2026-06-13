import Foundation

/// File-based persistence of the device's gateway credentials (what
/// redeem returns, protocol C.3.2) plus the passphrase that encrypts the
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
    }

    private static var fileURL: URL {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("application support directory is unavailable on this platform")
        }
        let dir = appSupport
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("matrix-session.json")
    }

    static func save(_ stored: Stored) throws(AppError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(stored)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.encode("matrix credentials: \(error.localizedDescription)")
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.storage("matrix credentials write: \(error.localizedDescription)")
        }
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
}
