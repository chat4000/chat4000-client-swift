import Foundation

/// v2 (Matrix) runtime configuration: which backend the client talks to, plus
/// on-disk locations for the Rust SDK's encrypted state store.
///
/// Hosts come straight from `chat4000-backend-depolyment-and-docs/docs/protocol.md`
/// (the Environments table). Selection follows the same dev/prod signal as
/// telemetry: a Debug build or a `.dev`-suffixed bundle id → **Stage**;
/// everything else → **Production**.
struct MatrixEnvironment {
    /// Tuwunel homeserver base URL (Matrix C-S API). matrix-rust-sdk connects
    /// here directly. Per protocol.md the spec'd client path is the WS gateway,
    /// but the SDK can't speak that custom frame protocol — and the homeserver
    /// is independently exposed — so we connect direct.
    let homeserverURL: String

    /// Registrar service base URL — accounts + device onboarding (`/pair/*`).
    let registrarBaseURL: String

    /// Where the homeserver POSTs pushes — the notification service, reachable
    /// by the homeserver on its internal compose network. The gateway normally
    /// injects this into the pusher; SDK-direct, the client sets it. Same value
    /// per env (each homeserver reaches its own notification service by name).
    let notificationPushURL = "http://notification:8070/_matrix/push/v1/notify"

    /// Whether this build targets Stage vs Production. Matches `TelemetryManager`'s dev tag.
    static var isStage: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        #endif
    }

    static var current: MatrixEnvironment {
        if isStage {
            // Stage — Hetzner `chat4000-stage` behind Duck DNS with a Let's
            // Encrypt wildcard cert (*.stgcht4.duckdns.org). Trusted HTTPS, so
            // no client-side TLS overrides are needed.
            return MatrixEnvironment(
                homeserverURL: "https://matrix.stgcht4.duckdns.org",
                registrarBaseURL: "https://registrar.stgcht4.duckdns.org"
            )
        }
        return MatrixEnvironment(
            homeserverURL: "https://matrix.chat4000.com",
            registrarBaseURL: "https://registrar.chat4000.com"
        )
    }

    /// Directory holding the SDK's encrypted SQLite state store (crypto + state).
    var sessionDataPath: String {
        Self.ensuredDirectory(in: .applicationSupportDirectory, leaf: "matrix-store")
    }

    /// Directory for the SDK's disposable caches.
    var sessionCachePath: String {
        Self.ensuredDirectory(in: .cachesDirectory, leaf: "matrix-cache")
    }

    private static func ensuredDirectory(in base: FileManager.SearchPathDirectory, leaf: String) -> String {
        let root = FileManager.default.urls(for: base, in: .userDomainMask).first!
        let dir = root
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
