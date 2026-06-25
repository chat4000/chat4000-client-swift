// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation
import Security

// ─────────────────────────────────────────────────────────────────────────────
// AppGroup — the per-flavor App-Group container shared by the iOS app and its
// Notification Service Extension (protocol F.2.3, F.2.4).
//
// WHY (F2): the app and the NSE are SEPARATE PROCESSES that must read the SAME
// crypto store (the same Megolm keys). iOS only lets two processes share files
// through an App Group, so the crypto store, the cross-process lockfile, and the
// generation counter all live in this container.
//
// PER-FLAVOR (F.2.4 "Per-flavor App Groups"): the dev build and the App Store
// build use SEPARATE App Group identifiers so a dev build and a shipped build
// never share one crypto store. The id is derived from the running bundle id:
//   • App Store app   com.neonnode.chat94app                → group.com.neonnode.chat94app
//   • Hermes dev app  com.neonnode.chat94app.dev.hermes     → group.com.neonnode.chat94app.dev.hermes
//   • OpenClaw dev    com.neonnode.chat94app.dev.openclaw   → group.com.neonnode.chat94app.dev.openclaw
//   • App Store NSE   com.neonnode.chat94app.nse            → group.com.neonnode.chat94app
//   • Hermes dev NSE  com.neonnode.chat94app.dev.hermes.nse → group.com.neonnode.chat94app.dev.hermes
// i.e. the NSE strips its `.nse` suffix to land in the SAME group as its app.
//
// This type hardcodes NOTHING about which target it runs in — it reads
// `Bundle.main.bundleIdentifier` and maps it to the flavor's group, so the same
// code resolves the right group in either process.
//
// macOS (protocol F.2 "iOS-only"): the App Group exists ONLY for the iOS app↔NSE
// split. macOS is a SINGLE process on the live WebSocket — it has NO NSE, NO
// shared App Group entitlement, and the Mac DMG build runs UNSANDBOXED. On an
// unsandboxed macOS process `FileManager.containerURL(forSecurityApplicationGroup
// Identifier:)` does NOT return nil even without the entitlement — it eagerly
// CREATES and returns `~/Library/Group Containers/<id>/`, which (a) triggers the
// "would like to access data from other apps" consent prompt and (b) makes the
// app open a FRESH, wrong crypto store there instead of its real sandbox store.
// So every App-Group-dependent member below is compiled OUT on macOS (returns
// nil), which makes every caller degrade to the pre-F2 sandbox / no-lock path.
// ─────────────────────────────────────────────────────────────────────────────

enum AppGroup {
    /// The App Store flavor's base bundle id (no suffix).
    private static let baseBundleId = "com.neonnode.chat94app"

    /// The shared keychain access group (F.2.3 "shared keychain"), FULLY QUALIFIED
    /// as `<AppIdentifierPrefix><flavor bundle id>.shared`. iOS keychain REQUIRES
    /// the team-id prefix on `kSecAttrAccessGroup`: the bare group is not an
    /// entitled access group, so `SecItem*` fail with errSecMissingEntitlement —
    /// which silently broke NSE credential sharing (the NSE saw "no shared
    /// credentials" and fell back to the generic banner). The prefix is derived
    /// ONCE at runtime from a throwaway keychain probe (computed by this `let`),
    /// falling back to the bare group only if the probe fails.
    ///
    /// PER-FLAVOR (F.2.4): the bare group is derived from the running flavor's
    /// bundle id (the NSE strips its `.nse` suffix to match its app — same rule as
    /// the App Group), so each flavor — App Store, Hermes dev, OpenClaw dev — has
    /// its OWN shared keychain group and they never read each other's
    /// `SharedCredentials`. The App Store flavor resolves to the historical
    /// `com.neonnode.chat94app.shared`, so shipped installs are unaffected. This
    /// MUST equal the target's `APP_KEYCHAIN_GROUP` build setting (the entitlement).
    static let keychainAccessGroup: String = {
        #if os(iOS)
        let bare = "\(flavorBundleId).shared"
        guard let prefix = keychainTeamPrefix() else { return bare }
        return prefix + bare
        #else
        // macOS: single process, no NSE, no keychain-access-group entitlement —
        // keep the base group (unprefixed).
        return "\(baseBundleId).shared"
        #endif
    }()

    #if os(iOS)
    /// Derive the `<TeamID>.` AppIdentifierPrefix by adding/reading a throwaway
    /// keychain item (no access group specified → lands in the app's DEFAULT group
    /// `<TeamID>.<bundleid>`) and inspecting its resolved access group.
    private static func keychainTeamPrefix() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "teamid-probe",
            kSecAttrService as String: "\(baseBundleId).teamid-probe"
        ]
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            var add = base
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &out)
        }
        guard status == errSecSuccess,
              let attrs = out as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".") else { return nil }
        return String(group[...dot])   // "<TeamID>."
    }
    #endif

    /// The per-flavor App Group identifier for the CURRENT process, derived from
    /// the running bundle id (see the file header for the mapping). iOS-only —
    /// nil on macOS (no App Group there; see the file header).
    static var identifier: String? {
        #if os(iOS)
        return "group.\(flavorBundleId)"
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// The flavor's app bundle id — the NSE's `.nse` suffix stripped so a NSE and
    /// its app resolve to the SAME flavor (and therefore the SAME group).
    private static var flavorBundleId: String {
        var id = Bundle.main.bundleIdentifier ?? baseBundleId
        if id.hasSuffix(".nse") { id = String(id.dropLast(".nse".count)) }
        return id
    }
    #endif

    /// The shared App-Group `UserDefaults` suite (F.2.4) — where the **to-device
    /// cursor** and the **live-sync heartbeat** live so the app and the NSE agree on
    /// them (protocol F.2.1b / D "Two drainers, one shared to-device cursor"). iOS
    /// only; nil on macOS (no App Group) and if the suite can't be opened, so callers
    /// fall back to `UserDefaults.standard` (app-local), preserving pre-F2 behavior.
    static var sharedDefaults: UserDefaults? {
        #if os(iOS)
        guard let identifier else { return nil }
        return UserDefaults(suiteName: identifier)
        #else
        return nil
        #endif
    }

    /// The shared App-Group container directory, or nil when the App Group is
    /// unavailable. On macOS this is ALWAYS nil (no App Group — see the file
    /// header), so the Mac app never touches a Group Container. On iOS it is nil
    /// only when the entitlement is missing/misconfigured (the caller falls back —
    /// the NSE bails to the generic banner, F.2.2; the app keeps its sandbox store).
    static var containerURL: URL? {
        #if os(iOS)
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        return nil
        #endif
    }

    /// The directory holding the standalone crypto store inside the shared
    /// container, namespaced per environment (mirrors the old sandbox layout so
    /// the migration is a like-for-like move). Returns nil if the container is
    /// unavailable. Does NOT create it — `cryptoStoreURL` (the caller) does.
    static func cryptoStoreDirectoryURL(namespace: String) -> URL? {
        guard let container = containerURL else { return nil }
        return container
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("matrix-crypto", isDirectory: true)
    }

    /// The sidecar lockfile URL (F.2.3) — a dedicated file to `flock`, NEVER the
    /// `.sqlite`/`-wal`/`-shm` files. Lives in the crypto-store directory so it
    /// travels with the store.
    static func lockfileURL(namespace: String) -> URL? {
        cryptoStoreDirectoryURL(namespace: namespace)?
            .appendingPathComponent("crypto-store.lock", isDirectory: false)
    }

    /// The generation-counter file URL (F.2.3 "reload on dirty"). Alongside the
    /// lockfile, in the crypto-store directory.
    static func generationURL(namespace: String) -> URL? {
        cryptoStoreDirectoryURL(namespace: namespace)?
            .appendingPathComponent("crypto-store.generation", isDirectory: false)
    }
}
