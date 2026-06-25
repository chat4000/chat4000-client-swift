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
        // F2 (protocol F.2.1 / F.2.3): mirror to the SHARED keychain so the NSE
        // process can read the access token + gateway URL + store path to fetch
        // and decrypt a pushed event. Keyed by `account_id` (= the pusher's
        // `data.account_id`). The file above stays the app's own source of truth;
        // this is the cross-process copy. A keychain miss is logged, not fatal —
        // the app still works; only the NSE would fall back to the generic banner.
        let accountId = SharedCredentials.accountId(userId: stored.userId, deviceId: stored.deviceId)
        let record = SharedCredentials.Record(
            accessToken: stored.accessToken,
            userId: stored.userId,
            deviceId: stored.deviceId,
            gatewayURL: stored.gatewayURL,
            cryptoStorePath: MatrixEnvironment.current.cryptoStorePath
        )
        SharedCredentials.save(record, accountId: accountId)
    }

    static func load() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        // F2: ensure the shared-keychain mirror exists so the NSE can read it even
        // for an install that paired BEFORE the mirror was written (or with the old
        // mismatched access group). Idempotent + cheap; only writes when absent.
        let accountId = SharedCredentials.accountId(userId: stored.userId, deviceId: stored.deviceId)
        if SharedCredentials.load(accountId: accountId) == nil {
            SharedCredentials.save(
                SharedCredentials.Record(
                    accessToken: stored.accessToken,
                    userId: stored.userId,
                    deviceId: stored.deviceId,
                    gatewayURL: stored.gatewayURL,
                    cryptoStorePath: MatrixEnvironment.current.cryptoStorePath
                ),
                accountId: accountId
            )
        }
        return stored
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        // F2: clear the shared-keychain mirror too so a signed-out device's NSE
        // can't fetch with a dead token.
        SharedCredentials.deleteAll()
        AppLog.log("💾 Matrix credentials deleted")
    }
}
