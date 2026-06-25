import Foundation

struct AppEnvironment {
    /// Stage vs Production — driven by the per-flavor `APP_ENV` build setting
    /// (surfaced via Info.plist, read in `MatrixEnvironment.isStage`), NOT by
    /// Debug/Release. So a dev-signed build can still target prod (the deployable
    /// prod flavor) and the dev flavors stay stage regardless of config.
    enum Kind: String {
        case stage
        case prod
    }

    let kind: Kind
    let storageNamespace: String

    static var current: AppEnvironment {
        AppEnvironment(
            kind: MatrixEnvironment.isStage ? .stage : .prod,
            storageNamespace: storageNamespace()
        )
    }

    /// On-disk crypto-store namespace. iOS isolates flavors via the per-flavor
    /// App-Group container (see `AppGroup`), so this just has to be stable AND
    /// identical for an app and its NSE — a fixed `v2`. macOS has no App Group, so
    /// flavors are isolated by bundle id in the shared Application Support dir. The
    /// `v2` value also abandons the legacy relay-hashed `production-<hash>` dir, so
    /// the store starts clean on upgrade (the v1 relay is gone).
    private static func storageNamespace() -> String {
        #if os(iOS)
        return "v2"
        #else
        return Bundle.main.bundleIdentifier ?? "com.neonnode.chat94app"
        #endif
    }
}

/// App version + bundle-id helper (was previously bundled with the v1 relay
/// registration code, which is now removed).
enum AppRegistrationIdentity {
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var currentAppId: String {
        Bundle.main.bundleIdentifier ?? ""
    }
}
