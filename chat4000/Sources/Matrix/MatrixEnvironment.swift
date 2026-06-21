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
    /// F2 (protocol F.2.3): on iOS the store lives in the per-flavor App-Group
    /// container so the app AND the NSE (a separate process) open the SAME store.
    /// No migration from the legacy sandbox path (not prod; a fresh App-Group store
    /// just re-syncs its keys). If the App-Group container is unavailable
    /// (entitlement missing / misconfigured) we fall back to the legacy sandbox
    /// path so the app keeps working; only the NSE (which needs the shared
    /// container) is then unavailable. macOS always uses the sandbox path.
    var cryptoStorePath: String {
        // macOS (protocol F.2 "iOS-only"): a SINGLE process on the live WebSocket,
        // no NSE and no App Group. It MUST use its pre-F2 sandbox store and must
        // NEVER touch a Group Container (`AppGroup` is nil-gated to iOS, so this
        // can't accidentally fall into the App-Group branch). Return sandbox path.
        #if os(iOS)
        let namespace = AppEnvironment.current.storageNamespace
        guard let groupDir = AppGroup.cryptoStoreDirectoryURL(namespace: namespace) else {
            // No App Group → can't share with the NSE. Keep using the sandbox
            // store (no migration, no key loss). iOS-only feature regardless.
            AppLog.log("🔐 App-Group container unavailable — using legacy sandbox crypto store")
            return Self.legacyCryptoStorePath
        }
        try? FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        Self.applyFileProtection(to: groupDir)
        return groupDir.path
        #else
        return Self.legacyCryptoStorePath
        #endif
    }

    /// The pre-F2 store location: the app sandbox's Application Support dir. Used
    /// as the fallback when there is no App Group, and on macOS.
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

    // MARK: - Crypto-store file protection (iOS-only, F.2)

    #if os(iOS)

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
