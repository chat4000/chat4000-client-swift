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
    var cryptoStorePath: String {
        Self.ensuredDirectory(in: .applicationSupportDirectory, leaf: "matrix-crypto")
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
