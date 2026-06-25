// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation
import Security

// ─────────────────────────────────────────────────────────────────────────────
// SharedCredentials — the device credentials the NSE needs, stored in the SHARED
// keychain access group so BOTH the app and the NSE process can read them
// (protocol F.2.1 "read by the NSE from the shared App-Group store", F.2.3).
//
// WHY a keychain item and not the App-Group file: tokens are secrets, and the
// keychain (a) is the right home for a bearer token, (b) is reachable from the
// extension process via a shared `kSecAttrAccessGroup`, and (c) survives
// independently of the crypto store. The NSE reads exactly the access token +
// the gateway base URL it needs to call `POST /_matrix/push/v1/fetch` (F.2.1).
//
// KEYED BY `account_id` (F.2.1, pusher `data.account_id`, protocol F): one device
// = one app install = one account, so in practice there is a single item, but the
// keychain account attribute is the `account_id` so the layout already supports
// the device naming the account it wants. `accountId(userId:deviceId:)` is the
// canonical derivation — the same string the pusher carries.
//
// FILE PROTECTION: `kSecAttrAccessibleAfterFirstUnlock` — readable by the NSE
// after the user has unlocked the device once since boot, which matches the
// crypto store's `completeUntilFirstUserAuthentication` (F.2). A push that
// arrives before first unlock simply can't fetch and falls back (F.2.2).
// ─────────────────────────────────────────────────────────────────────────────

enum SharedCredentials {
    /// Everything the NSE (and the app) needs to fetch + decrypt one event.
    struct Record: Codable, Equatable {
        var accessToken: String
        var userId: String
        var deviceId: String
        /// The WS gateway URL (`gateway_url` from redeem). The NSE derives the
        /// HTTPS base from it to reach `POST /_matrix/push/v1/fetch` (F.2.1).
        var gatewayURL: String
        /// The crypto-store path (App-Group container). The NSE opens the store
        /// here to decrypt locally (F.2.3).
        var cryptoStorePath: String
    }

    /// The canonical `account_id` for a device's account: `userId|deviceId`.
    /// Stamped on the pusher `data.account_id` (F) and used as the keychain
    /// account attribute, so the NSE could resolve the exact account if more than
    /// one ever existed. (Format is a chat4000 convention — there is one account
    /// per device, so any stable per-account string would do.)
    static func accountId(userId: String, deviceId: String) -> String {
        "\(userId)|\(deviceId)"
    }

    private static let service = "com.neonnode.chat94app.shared-credentials"

    /// Persist (or overwrite) the record for `accountId` in the shared keychain
    /// access group. Idempotent: deletes any existing item for the account first,
    /// then adds. Returns false on a keychain error (logged) so the caller knows
    /// the NSE may not be able to read it — the app still works off its own file.
    @discardableResult
    static func save(_ record: Record, accountId: String) -> Bool {
        // iOS-only (protocol F.2 "iOS-only"): macOS has no NSE and no shared App
        // Group / keychain access group, so writing here would only log a
        // keychain-entitlement error. Skip entirely on macOS — the Mac app keeps
        // using its own credential file, behavior unchanged.
        #if !os(iOS)
        return false
        #else
        guard let data = try? JSONEncoder().encode(record) else { return false }
        // Delete any prior item for this account (update-in-place across an
        // access group is finicky; delete+add is simplest and atomic enough here).
        SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
        var add = baseQuery(accountId: accountId)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.log("🔑 SharedCredentials.save failed status=%d account=%@ group=%@", Int(status), accountId, AppGroup.keychainAccessGroup)
            return false
        }
        AppLog.log("🔑 SharedCredentials.save ok account=%@ group=%@", accountId, AppGroup.keychainAccessGroup)
        return true
        #endif
    }

    /// Read the record for `accountId`, or nil if absent / unreadable.
    static func load(accountId: String) -> Record? {
        var query = baseQuery(accountId: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Read the single stored record without naming an account — the common NSE
    /// path, since one device holds exactly one account. Returns nil if none.
    static func loadAny() -> Record? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Remove the item for `accountId` (sign-out / re-pair).
    static func delete(accountId: String) {
        SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
    }

    /// Remove every shared-credentials item (sign-out clears any account).
    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup
        ]
    }
}
