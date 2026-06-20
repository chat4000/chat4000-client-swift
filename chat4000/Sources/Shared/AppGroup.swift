// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

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
//   • App Store app  com.neonnode.chat94app       → group.com.neonnode.chat94app
//   • Dev app        com.neonnode.chat94app.dev   → group.com.neonnode.chat94app.dev
//   • App Store NSE  com.neonnode.chat94app.nse       → group.com.neonnode.chat94app
//   • Dev NSE        com.neonnode.chat94app.dev.nse   → group.com.neonnode.chat94app.dev
// i.e. the NSE strips its `.nse` suffix to land in the SAME group as its app.
//
// This type hardcodes NOTHING about which target it runs in — it reads
// `Bundle.main.bundleIdentifier` and maps it to the flavor's group, so the same
// code resolves the right group in either process.
// ─────────────────────────────────────────────────────────────────────────────

enum AppGroup {
    /// The App Store flavor's base bundle id (no suffix).
    private static let baseBundleId = "com.neonnode.chat94app"

    /// The shared keychain access group (F.2.3 "shared keychain"). The
    /// access-group string in the entitlement is `$(AppIdentifierPrefix)<group>`;
    /// `SecItem` matches on the bare group WITHOUT the team prefix, so callers use
    /// this constant directly as `kSecAttrAccessGroup`.
    static let keychainAccessGroup = "\(baseBundleId).shared"

    /// The per-flavor App Group identifier for the CURRENT process, derived from
    /// the running bundle id (see the file header for the mapping).
    static var identifier: String {
        "group.\(flavorBundleId)"
    }

    /// The flavor's app bundle id — the NSE's `.nse` suffix stripped so a NSE and
    /// its app resolve to the SAME flavor (and therefore the SAME group).
    private static var flavorBundleId: String {
        var id = Bundle.main.bundleIdentifier ?? baseBundleId
        if id.hasSuffix(".nse") { id = String(id.dropLast(".nse".count)) }
        return id
    }

    /// The shared App-Group container directory, or nil when the App Group
    /// entitlement is missing/misconfigured (the caller must then fall back —
    /// the NSE bails to the generic banner, F.2.2; the app keeps its sandbox store).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
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
