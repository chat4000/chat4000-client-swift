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

        guard let clear = try? engine.decrypt(eventJSON: cipherEvent, roomId: roomId) else {
            // Key-not-local is EXPECTED (F.2.2) — the cold-key push. Generic body.
            AppLog.log("🔔 [nse] local decrypt missed (no local key) — generic fallback")
            return nil
        }

        // (4) Cleartext → banner. The builder drops tool transcripts and unknown
        // types to the generic body (F.2.2 content mapping). If it returns the
        // fallback, surface nil so the caller keeps the unmodified placeholder.
        let content = NotificationContentBuilder.build(fromClearEventJSON: clear)
        if content == NotificationContentBuilder.fallback {
            return nil
        }
        return content
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
}
