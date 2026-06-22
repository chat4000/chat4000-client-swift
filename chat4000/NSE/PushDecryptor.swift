// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PushDecryptor — the NSE's decrypt-only worker (protocol F.2.1 / F.2.2 / F.2.3).
//
// It turns one (room_id, event_id) reference from a push into one banner string:
//   1. Resolve the device's credentials from the SHARED keychain (F.2.1).
//   2. FETCH the ciphertext event over the network FIRST, with NO lock held
//      (F.2.2 step 2 / F.2.3 "fetch BEFORE lock"): POST /_matrix/push/v1/fetch.
//   3. Take the CryptoStoreLock and decrypt the fetched event with the LOCAL
//      Megolm key only (F.2.2 step 3); the lock is taken ONLY around the decrypt
//      (CryptoEngine does this internally via its injected storeLock), then
//      released — never across the network.
//   4. Map the cleartext to a banner via NotificationContentBuilder.
//
// DECRYPT-ONLY (F.2.2 / F.2.5): never encrypt, send, share keys, claim OTKs, run
// a sync, or drain to-device. It opens the OlmMachine, decrypts with whatever key
// is already local, and on ANY miss (no key, fetch error, expired token, timeout)
// returns nil so the caller falls back to the generic banner. It opens NO
// WebSocket and NO C-S API directly — the gateway `fetch` endpoint is the only
// door (F.2.1).
// ─────────────────────────────────────────────────────────────────────────────

/// A `GatewayRequesting` that refuses every call. The NSE constructs a
/// `CryptoEngine` only to DECRYPT; decrypt never issues outgoing crypto requests,
/// so this stub is never actually invoked. If some path ever did try to use it,
/// it fails closed (the NSE then falls back to the generic banner) rather than
/// opening any network/crypto write the NSE must never perform (F.2.5).
@MainActor
private final class NoGateway: GatewayRequesting {
    func request(method: String, path: String, body: [String: Any]?) async throws(AppError) -> (status: Int, body: Data) {
        throw AppError.notReady
    }
}

@MainActor
enum PushDecryptor {
    /// Decrypt the event referenced by a push and return banner content, or nil to
    /// fall back to the generic placeholder (F.2.2 step 5).
    ///
    /// - `roomId` / `eventId`: the references from the F.2 payload.
    /// - `accountId`: the pusher's `data.account_id` (F), naming which stored
    ///   account to use; nil → use the single stored account.
    static func decryptBanner(
        roomId: String,
        eventId: String,
        accountId: String?
    ) async -> NotificationContentBuilder.Content? {
        // (1) Resolve credentials from the shared keychain (F.2.1). Bail (→ generic
        // fallback) if the App-Group/keychain is unreadable — never exit(0); the
        // OS shows the unmodified placeholder.
        guard let record = resolveCredentials(accountId: accountId) else {
            AppLog.log("🔔 [nse] no shared credentials — generic fallback")
            return nil
        }
        guard let mediaBase = MatrixEnvironment.mediaBaseURL(fromGatewayURL: record.gatewayURL) else {
            AppLog.log("🔔 [nse] bad gateway URL — generic fallback")
            return nil
        }

        // (2) FETCH the ciphertext FIRST, no lock held (F.2.2 step 2 / F.2.3).
        let cipherEvent: String
        do {
            cipherEvent = try await fetchEvent(
                roomId: roomId, eventId: eventId,
                gatewayHTTPBase: mediaBase, accessToken: record.accessToken
            )
        } catch {
            AppLog.log("🔔 [nse] fetch failed (%@) — generic fallback", String(describing: error))
            return nil
        }

        // (3) Open the SAME store the app uses, wired to the SAME cross-process
        // lock, and decrypt UNDER the lock only (CryptoEngine.decrypt takes the
        // lock internally, reloads-if-dirty, releases immediately — F.2.3). The
        // OlmMachine is deallocated when `engine` goes out of scope at return,
        // satisfying "release the flock and deallocate the OlmMachine before the
        // extension returns" (F.2.3, 0xdead10cc).
        let namespace = AppEnvironment.current.storageNamespace
        let storeLock: CryptoStoreLock? = {
            guard let lockURL = AppGroup.lockfileURL(namespace: namespace),
                  let genURL = AppGroup.generationURL(namespace: namespace) else { return nil }
            return CryptoStoreLock(lockfileURL: lockURL, generationURL: genURL)
        }()
        guard storeLock != nil else {
            AppLog.log("🔔 [nse] no App-Group lock — generic fallback")
            return nil
        }

        let engine: CryptoEngine
        do {
            engine = try CryptoEngine(
                userId: record.userId,
                deviceId: record.deviceId,
                storePath: record.cryptoStorePath,
                gateway: NoGateway(),
                storeLock: storeLock
            )
        } catch {
            AppLog.log("🔔 [nse] crypto store open failed (%@) — generic fallback", String(describing: error))
            return nil
        }

        if let clear = try? engine.decrypt(eventJSON: cipherEvent, roomId: roomId) {
            return banner(fromClear: clear)
        }

        // (4) COLD-KEY RECOVERY (protocol F.2.1b). The room key isn't local — the
        // common cause is a freshly-minted Megolm session whose to-device key arrived
        // while the app was SUSPENDED, so the app never synced it into the store. If
        // the app isn't live-syncing (heartbeat stale), do a one-shot NORMAL gateway
        // sync here: import the to-device keys into the SAME shared store under the
        // flock, advance the shared cursor, then retry the decrypt ONCE. If the app
        // IS live, or recovery doesn't yield the key, fall back to the generic banner.
        AppLog.log("🔔 [nse] local decrypt missed — attempting cold-key recovery")
        let recovered = await coldKeyRecover(record: record, engine: engine)
        guard recovered, let clear = try? engine.decrypt(eventJSON: cipherEvent, roomId: roomId) else {
            AppLog.log("🔔 [nse] cold-key recovery did not yield the key — generic fallback")
            return nil
        }
        AppLog.log("🔔 [nse] cold-key recovery succeeded — decrypted after drain")
        return banner(fromClear: clear)
    }

    /// Cleartext event JSON → banner content, or nil to keep the generic placeholder.
    /// The builder drops tool transcripts + unknown types to the fallback (F.2.2
    /// content mapping); a fallback result surfaces nil (keep the placeholder).
    private static func banner(fromClear clear: String) -> NotificationContentBuilder.Content? {
        let content = NotificationContentBuilder.build(fromClearEventJSON: clear)
        return content == NotificationContentBuilder.fallback ? nil : content
    }

    // MARK: - Credentials

    private static func resolveCredentials(accountId: String?) -> SharedCredentials.Record? {
        if let accountId, let exact = SharedCredentials.load(accountId: accountId) {
            return exact
        }
        return SharedCredentials.loadAny()
    }

    // MARK: - Gateway event fetch (F.2.1)

    enum FetchError: Error { case badURL, http(Int), empty }

    /// `POST /_matrix/push/v1/fetch` on the gateway host, device-token auth
    /// (F.2.1). Returns the raw `m.room.encrypted` event JSON verbatim. NO lock is
    /// held here (F.2.3 "fetch BEFORE lock").
    private static func fetchEvent(
        roomId: String,
        eventId: String,
        gatewayHTTPBase: String,
        accessToken: String
    ) async throws -> String {
        guard let url = URL(string: "\(gatewayHTTPBase)/_matrix/push/v1/fetch") else {
            throw FetchError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A short timeout — the NSE has a hard wall-clock budget; a slow fetch
        // must fall back rather than block to expiry.
        req.timeoutInterval = 10
        req.httpBody = try JSONSerialization.data(withJSONObject: ["room_id": roomId, "event_id": eventId])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Mirrors the homeserver status (F.2.1): 401/403 expired token, 404 gone →
        // fall back. Any non-2xx → throw → generic banner.
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw FetchError.empty }
        return text
    }

    // MARK: - Cold-key recovery (one-shot NORMAL sync — protocol F.2.1b)

    /// Heartbeat staleness (s): a heartbeat older than this means the app isn't
    /// live-syncing, so the NSE may drain (single-writer on the shared cursor).
    private static let liveSyncThresholdSeconds: TimeInterval = 8
    /// Hard wall-clock cap (s) on the whole recovery — the NSE has a short OS budget,
    /// so a silent/slow gateway must never hang it; the watchdog cancels the socket.
    private static let recoveryBudgetSeconds: TimeInterval = 10

    /// True when the app is live-syncing (heartbeat fresh) — the NSE then MUST NOT
    /// drain (the app owns cursor advancement and will deliver the key). A stale or
    /// missing heartbeat → app suspended → NSE may drain.
    private static func appIsLiveSyncing(userId: String) -> Bool {
        let key = "chat4000.liveSyncHeartbeat.\(userId)"
        guard let ts = (AppGroup.sharedDefaults ?? .standard).object(forKey: key) as? Double else { return false }
        return Date().timeIntervalSince1970 - ts < liveSyncThresholdSeconds
    }

    private static func toDevicePosKey(_ userId: String) -> String { "chat4000.toDevicePos.\(userId)" }
    private static func loadSharedToDevicePos(_ userId: String) -> String? {
        (AppGroup.sharedDefaults ?? .standard).string(forKey: toDevicePosKey(userId))
    }
    private static func saveSharedToDevicePos(_ pos: String, _ userId: String) {
        (AppGroup.sharedDefaults ?? .standard).set(pos, forKey: toDevicePosKey(userId))
    }

    /// One-shot NORMAL gateway sync to import cold keys into the shared store under
    /// the flock (F.2.1b). Connects to the SAME `/ws` the app uses, auths, runs ONE
    /// sync from the shared `to_device_pos` (the gateway injects the to-device
    /// extension), imports the to-device keys via the SAME `CryptoEngine` (which
    /// takes the F.2.3 flock), advances the shared cursor AFTER the import (anti-UTD),
    /// and returns true iff it imported ≥1 to-device event. Best-effort: any failure
    /// → false. Gated on the live-sync heartbeat so it never races the app's sync.
    private static func coldKeyRecover(record: SharedCredentials.Record, engine: CryptoEngine) async -> Bool {
        if appIsLiveSyncing(userId: record.userId) {
            AppLog.log("🔔 [nse] app is live-syncing — skip cold-key drain, fall back")
            return false
        }
        guard let wsURL = URL(string: record.gatewayURL) else { return false }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        // Watchdog: hard-cancel the socket after the budget so a silent/slow gateway
        // can never hang the NSE to its OS deadline.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(recoveryBudgetSeconds * 1_000_000_000))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // auth → auth_ok
        guard await send(task, authFrame(record)),
              let auth = await receive(task), (auth["t"] as? String) == "auth_ok" else {
            AppLog.log("🔔 [nse] cold-key sync: auth failed/timeout")
            return false
        }
        // sync_start from the shared cursor — the gateway adds the to-device extension
        // with `since` = our `to_device_pos`.
        guard await send(task, syncStartFrame(record)) else { return false }

        // Read frames until a `sync` arrives (ignore others); the watchdog bounds it.
        while true {
            guard let frame = await receive(task) else { return false }
            guard (frame["t"] as? String) == "sync" else { continue }
            let sync = SyncModel.parse(frame)
            guard !sync.toDevice.isEmpty else {
                AppLog.log("🔔 [nse] cold-key sync: 0 to-device events — nothing to import")
                return false
            }
            do {
                try engine.receiveSyncChangesIntoStore(sync)   // imports keys under the flock
            } catch {
                AppLog.log("🔔 [nse] cold-key import failed: %@", String(describing: error))
                return false
            }
            // Advance the SHARED cursor ONLY after the keys are durably imported
            // (anti-UTD): a crash before this re-delivers the batch, never loses it.
            if let td = sync.toDevicePos { saveSharedToDevicePos(td, record.userId) }
            AppLog.log("🔔 [nse] cold-key sync imported %d to-device event(s)", sync.toDevice.count)
            return true
        }
    }

    private static func authFrame(_ record: SharedCredentials.Record) -> [String: Any] {
        var appId = Bundle.main.bundleIdentifier ?? "com.neonnode.chat94app"
        if appId.hasSuffix(".nse") { appId = String(appId.dropLast(".nse".count)) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return [
            "t": "auth", "access_token": record.accessToken, "app_id": appId,
            "client_version": version, "platform": "ios", "release_channel": "production"
        ]
    }

    private static func syncStartFrame(_ record: SharedCredentials.Record) -> [String: Any] {
        var frame: [String: Any] = ["t": "sync_start", "body": ["lists": [String: Any]()]]
        if let td = loadSharedToDevicePos(record.userId) { frame["to_device_pos"] = td }
        return frame
    }

    private static func send(_ task: URLSessionWebSocketTask, _ frame: [String: Any]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return false }
        do { try await task.send(.string(text)); return true } catch { return false }
    }

    private static func receive(_ task: URLSessionWebSocketTask) async -> [String: Any]? {
        guard let message = try? await task.receive() else { return nil }
        let data: Data?
        switch message {
        case .string(let s): data = s.data(using: .utf8)
        case .data(let d): data = d
        @unknown default: data = nil
        }
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }
}
