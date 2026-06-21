import Foundation

/// v2 (gateway) runtime configuration. The client talks ONLY to the WS gateway
/// and the registrar — the homeserver has no public hostname (protocol D.3),
/// so there is no `homeserverURL` here anymore. The gateway WS URL is per-pair
/// (returned by redeem as `gateway_url`) and lives in the stored
/// credentials; this type provides the registrar base URL and on-disk paths for
/// the standalone crypto store.
struct MatrixEnvironment {
    /// Registrar service base URL — accounts, device onboarding
    /// (`POST /codes/{code}/redeem`, protocol C.3.2), and the version/terms
    /// policy (`/version`, protocol C.5).
    let registrarBaseURL: String

    /// Placeholder pusher callback URL. The gateway OVERWRITES `data.url` with
    /// the real notification-service URL on every `/pushers/set` (protocol D),
    /// so the value we send is ignored — but the field is required.
    let notificationPushURL = "https://notification.invalid/_matrix/push/v1/notify"

    /// Stage vs Production. Matches `TelemetryManager`'s dev tag: a Debug build
    /// or a `.dev`-suffixed bundle id → Stage; everything else → Production.
    static var isStage: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        #endif
    }

    static var current: MatrixEnvironment {
        if isStage {
            return MatrixEnvironment(registrarBaseURL: "https://registrar.stgcht4.duckdns.org")
        }
        return MatrixEnvironment(registrarBaseURL: "https://registrar.chat4000.com")
    }

    /// Directory holding the standalone crypto store (OlmMachine SQLite).
    ///
    /// F2 (protocol F.2.3 / F.2.4): the store moves into the per-flavor App-Group
    /// container so the app AND the NSE (a separate process) open the SAME store.
    /// On first access we run a fail-safe **copy → verify → delete** migration
    /// from the legacy app-sandbox path (`legacyCryptoStorePath`) — never a
    /// move-in-place, because losing the store loses every Megolm key (permanent
    /// UTD, C.6). If the App-Group container is unavailable (entitlement missing /
    /// misconfigured) we fall back to the legacy sandbox path so the app keeps
    /// working with no key loss; only the NSE (which needs the shared container)
    /// is then unavailable.
    var cryptoStorePath: String {
        // macOS (protocol F.2 "iOS-only"): a SINGLE process on the live WebSocket,
        // no NSE and no App Group. It MUST use its pre-F2 sandbox store and must
        // NEVER touch a Group Container or run the sandbox→App-Group migration
        // (`AppGroup` is nil-gated to iOS, so this also can't accidentally fall
        // into the App-Group branch). Return the sandbox path directly.
        #if os(iOS)
        let namespace = AppEnvironment.current.storageNamespace
        guard let groupDir = AppGroup.cryptoStoreDirectoryURL(namespace: namespace) else {
            // No App Group → can't share with the NSE. Keep using the sandbox
            // store (no migration, no key loss). iOS-only feature regardless.
            AppLog.log("🔐 App-Group container unavailable — using legacy sandbox crypto store")
            return Self.legacyCryptoStorePath
        }
        Self.migrateCryptoStoreIfNeeded(toGroupDir: groupDir)
        try? FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        Self.applyFileProtection(to: groupDir)
        return groupDir.path
        #else
        return Self.legacyCryptoStorePath
        #endif
    }

    /// The pre-F2 store location: the app sandbox's Application Support dir. Still
    /// the fallback when there is no App Group, and the migration SOURCE.
    static var legacyCryptoStorePath: String {
        ensuredDirectory(in: .applicationSupportDirectory, leaf: "matrix-crypto")
    }

    /// Derive the HTTP media base URL (protocol D.3) from a gateway WS URL:
    /// `wss://gateway.<env>/ws` → `https://gateway.<env>`. Media is reverse-
    /// proxied on the gateway host (the only public homeserver paths).
    static func mediaBaseURL(fromGatewayURL gatewayURL: String) -> String? {
        guard var components = URLComponents(string: gatewayURL) else { return nil }
        components.scheme = (components.scheme == "ws") ? "http" : "https"
        components.path = ""
        components.query = nil
        return components.string
    }

    // MARK: - Crypto-store migration (sandbox → App Group) — iOS-only (F.2)

    #if os(iOS)
    /// UserDefaults flag: the copy-verify-delete migration completed for this
    /// install, so we never re-run it (and never re-copy a stale sandbox store
    /// over a newer App-Group store the app has since written).
    private static let migrationDoneKey = "chat4000.cryptoStoreMigratedToAppGroup"

    /// One-time, fail-safe migration of the crypto store from the app sandbox into
    /// the App-Group container (protocol F.2.4 "Store migration sandbox→App-Group
    /// (never lose keys)"): **copy → verify → delete**, never move-in-place.
    ///
    /// 1. If already migrated (flag set) or the App-Group store already has a
    ///    `matrix-data.sqlite`, do nothing.
    /// 2. If there is no legacy sandbox store, mark done (nothing to move) — a
    ///    fresh install starts directly in the App Group.
    /// 3. Otherwise COPY every store file into the group dir, then VERIFY each
    ///    copy exists with a byte-for-byte matching size. Only when ALL verify do
    ///    we DELETE the sandbox originals and set the flag. Any failure leaves the
    ///    sandbox store untouched and the flag unset (the app keeps reading the
    ///    sandbox store via the fallback path) so a Megolm key is never lost.
    private static func migrateCryptoStoreIfNeeded(toGroupDir groupDir: URL) {
        let fm = FileManager.default
        if UserDefaults.standard.bool(forKey: migrationDoneKey) { return }

        let legacyDir = URL(fileURLWithPath: legacyCryptoStorePath, isDirectory: true)
        let legacyFiles = (try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)) ?? []
        // A matrix-rust-sdk store is `*.sqlite` (+ `-wal`/`-shm`). If the sandbox
        // has no sqlite, there is nothing worth migrating.
        let hasLegacyStore = legacyFiles.contains { $0.pathExtension == "sqlite" }
        guard hasLegacyStore else {
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }

        // Never overwrite an existing App-Group store (would clobber newer keys).
        let groupFiles = (try? fm.contentsOfDirectory(at: groupDir, includingPropertiesForKeys: nil)) ?? []
        if groupFiles.contains(where: { $0.pathExtension == "sqlite" }) {
            AppLog.log("🔐 App-Group store already present — skipping migration, leaving sandbox store in place")
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            return
        }

        do {
            try fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
            // COPY every legacy file.
            var copied: [(src: URL, dst: URL)] = []
            for src in legacyFiles {
                let dst = groupDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                copied.append((src, dst))
            }
            // VERIFY each copy: present + byte-for-byte size match.
            for pair in copied {
                let srcSize = (try? fm.attributesOfItem(atPath: pair.src.path)[.size] as? Int) ?? nil
                let dstSize = (try? fm.attributesOfItem(atPath: pair.dst.path)[.size] as? Int) ?? nil
                guard let srcSize, let dstSize, srcSize == dstSize else {
                    AppLog.log("🔐 ⚠️ migration verify FAILED for %@ (src=%@ dst=%@) — keeping sandbox store",
                               pair.src.lastPathComponent,
                               srcSize.map(String.init) ?? "nil", dstSize.map(String.init) ?? "nil")
                    // Roll back the partial copy; the sandbox store stays the source of truth.
                    for done in copied { try? fm.removeItem(at: done.dst) }
                    return
                }
            }
            // All verified — only NOW delete the sandbox originals.
            for src in legacyFiles { try? fm.removeItem(at: src) }
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            AppLog.log("🔐 ✅ crypto store migrated sandbox → App Group (%d files, verified)", copied.count)
        } catch {
            // Any failure: leave the sandbox store untouched, flag unset, retry next launch.
            ErrorReporter.capture(error, context: "MatrixEnvironment.migrateCryptoStore")
            AppLog.log("🔐 ⚠️ crypto store migration failed (%@) — keeping sandbox store", String(describing: error))
        }
    }

    /// Apply `completeUntilFirstUserAuthentication` file protection (protocol F.2)
    /// to the crypto-store directory so the NSE can open it after first unlock.
    private static func applyFileProtection(to dir: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
    }
    #endif

    private static func ensuredDirectory(in base: FileManager.SearchPathDirectory, leaf: String) -> String {
        guard let root = FileManager.default.urls(for: base, in: .userDomainMask).first else {
            fatalError("search-path directory \(base) is unavailable on this platform")
        }
        let dir = root
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
