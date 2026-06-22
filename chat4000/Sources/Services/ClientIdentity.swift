import Foundation
import Security

/// Analytics identity for this device (analytics plan IDN1 / IDN2 / IDN3).
///
/// - `client_id` (IDN1): a UUID stored in the Keychain with `ThisDeviceOnly`
///   accessibility — the PostHog `distinct_id`. It SURVIVES an app reinstall
///   (keychain persists on-device) but NOT a wipe / new hardware (ThisDeviceOnly
///   is never synced to iCloud Keychain). Created lazily, only while telemetry is
///   ON; deleted on opt-out so a later reinstall cannot re-link.
/// - `app_device_id` (IDN2): a UUID in UserDefaults (the app sandbox) — local
///   only, NEVER transmitted. Dies on reinstall, migrates via an encrypted device
///   backup. Exists solely to drive IDN3.
/// - First-launch classifier (IDN3): comparing which of the two markers is present
///   yields exactly one of `app_installed` / `app_reinstalled` / `device_swapped`.
enum ClientIdentity {
    /// Keychain service. On macOS it is namespaced PER FLAVOR (by bundle id) so
    /// prod / Hermes / OpenClaw never share one item. The macOS *file* keychain
    /// ACL-locks each item to the CREATING app's code signature, so a SHARED item
    /// read by another flavor popped the "<app> wants to use your confidential
    /// information stored in com.neonnode.chat4000.analytics" dialog. Per-flavor
    /// names mean each flavor only ever touches the item it created itself → no
    /// cross-flavor prompt. iOS keeps the bare name: its keychain already isolates
    /// items per app (default access group) and never shows this dialog, so
    /// renaming there would only reset existing installs' ids for no benefit.
    private static let keychainService: String = {
        let base = "com.neonnode.chat4000.analytics"
        #if os(macOS)
        if let bundleId = Bundle.main.bundleIdentifier { return base + "." + bundleId }
        #endif
        return base
    }()
    private static let keychainAccount = "client_id"
    private static let appDeviceIdKey = "chat4000.analytics.appDeviceId"

    // MARK: - client_id (IDN1, Keychain, ThisDeviceOnly)

    /// The stored client_id, if any. Does NOT create one.
    static func existingClientId() -> String? { keychainRead() }

    /// FLW1/FLW5 — the `X-Client-Id` header value: the client_id while telemetry is
    /// ON, else nil so the networking layers omit the header entirely. Nonisolated:
    /// safe to read off the main actor from the request builders.
    static func headerClientId() -> String? {
        guard TelemetryPreferences.isCollectionEnabled else { return nil }
        return existingClientId()
    }

    /// Returns the client_id, creating + persisting one if absent. Call only while
    /// telemetry is enabled (a fresh id must never be minted with telemetry off).
    @discardableResult
    static func ensureClientId() -> String {
        if let existing = keychainRead() { return existing }
        let id = UUID().uuidString
        keychainWrite(id)
        AppLog.log("🪪 minted client_id")
        return id
    }

    /// Opt-out: delete the client_id so a later reinstall cannot re-link. Also
    /// clears the local app_device_id marker so a future opt-in starts a clean
    /// identity (otherwise re-enabling telemetry would misfire `device_swapped`).
    static func clearForOptOut() {
        keychainDelete()
        UserDefaults.standard.removeObject(forKey: appDeviceIdKey)
        AppLog.log("🪪 cleared analytics identity (opt-out)")
    }

    // MARK: - app_device_id (IDN2, UserDefaults sandbox marker)

    static func existingAppDeviceId() -> String? {
        UserDefaults.standard.string(forKey: appDeviceIdKey)
    }

    @discardableResult
    static func ensureAppDeviceId() -> String {
        if let existing = existingAppDeviceId() { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: appDeviceIdKey)
        return id
    }

    // MARK: - First-launch classifier (IDN3)

    enum FirstLaunch {
        /// Both markers already present → an ordinary launch, no CL3/4/5 event.
        case normalLaunch
        case installed       // both missing → CL3 app_installed
        case reinstalled     // client_id survived, sandbox marker gone → CL4
        case deviceSwapped   // sandbox marker survived (backup), keychain gone → CL5
    }

    /// Classify THIS launch from which markers exist — read BEFORE any are
    /// created. The caller writes both markers afterwards (`ensureClientId` +
    /// `ensureAppDeviceId`), so the next launch reads `.normalLaunch`. Runs once
    /// per (re)install because creating the markers makes it idempotent.
    static func classifyFirstLaunch() -> FirstLaunch {
        switch (existingClientId() != nil, existingAppDeviceId() != nil) {
        case (true, true): return .normalLaunch
        case (false, false): return .installed
        case (true, false): return .reinstalled
        case (false, true): return .deviceSwapped
        }
    }

    // MARK: - Keychain primitives

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func keychainRead() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func keychainWrite(_ value: String) {
        let data = Data(value.utf8)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    private static func keychainDelete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
