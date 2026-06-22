import Foundation

/// Native client for the chat4000 WS gateway (protocol D): a single WebSocket
/// that authenticates, runs the sliding-sync loop, and multiplexes Matrix C-S
/// calls as `req`/`resp` frames. This is the **transport half** of the
/// gateway-native client (Option 2). End-to-end crypto (Olm/Megolm) and the
/// room/timeline model are layered on top of this.
///
/// Frame shapes mirror `chat4000-matrix-ws-proxy/src/protocol.rs`.
@MainActor
final class GatewayClient: GatewayRequesting {
    struct Identity {
        let appId: String
        let clientVersion: String
        let platform: String
        let releaseChannel: String
    }

    struct AuthResult { let userId: String; let deviceId: String }

    struct VersionWindow: Equatable {
        let minClientVersion: String?
        let maxClientVersion: String?
    }

    enum GatewayError: LocalizedError {
        case badURL
        case notConnected
        case authError(String)
        case unsupportedClientVersion(VersionWindow)
        case socketClosed
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL: "Invalid gateway URL"
            case .notConnected: "Gateway not connected"
            case .authError(let r): "Gateway auth failed: \(r)"
            case .unsupportedClientVersion: "Gateway auth failed: unsupported client version"
            case .socketClosed: "Gateway socket closed"
            case .requestFailed(let r): "Gateway request failed: \(r)"
            }
        }

        /// Map this transport error onto the closed `AppError` domain so the
        /// gateway's typed-throws boundary (`connect`/`request`) surfaces only
        /// `AppError`. Preserves the prior user-facing distinction (not-ready vs.
        /// auth vs. network).
        var asAppError: AppError {
            switch self {
            case .badURL: .invalidConfiguration("gateway URL")
            case .notConnected, .socketClosed: .notReady
            case .authError(let r): .pairing(r)
            case .unsupportedClientVersion(let window):
                .unsupportedClientVersion(
                    minClientVersion: window.minClientVersion,
                    maxClientVersion: window.maxClientVersion
                )
            case .requestFailed(let r): .network(r)
            }
        }
    }

    private let url: URL
    private let identity: Identity
    private var accessToken: String

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Set by `disconnect()` so the receive loop's resulting error does not fire
    /// `onClosed` (which would trigger a spurious reconnect on a clean close).
    private var isClosing = false

    /// Pending `req` continuations keyed by frame id. Body is raw JSON `Data`
    /// (Sendable) — callers parse it; `[String: Any]` can't cross a continuation.
    private var pending: [String: CheckedContinuation<(status: Int, body: Data), Error>] = [:]
    private var reqCounter = 0
    /// Resolved once on the first `auth_ok` / `auth_error`.
    private var authContinuation: CheckedContinuation<AuthResult, Error>?

    /// Last sliding-sync request body + cursor (replayed on reconnect/resume).
    private var syncBody: [String: Any]?
    private var syncPos: String?
    /// The to-device cursor (protocol D.1 two-cursor sliding sync) — a SEPARATE
    /// counter from `pos`, NEVER derived from it. Carries the Olm-wrapped Megolm
    /// room keys; replayed in `sync_start`/`sync_ack` so un-acked keys are never
    /// deleted before the device persists them.
    private var syncToDevicePos: String?

    /// Pushes each `sync` frame's top-level object (pos/rooms/extensions).
    var onSync: (([String: Any]) -> Void)?
    /// The gateway sent a `sync_reset` (protocol D.1/D.2 cursor-expiry recovery):
    /// the homeserver rejected the room cursor with `M_UNKNOWN_POS`, the gateway
    /// already dropped the named cursor(s) and re-initialised the upstream sync on
    /// THIS same socket. The argument is `cursors` — the durably-persisted cursor
    /// names the device MUST immediately discard so a later reconnect cannot replay
    /// them (e.g. `["pos"]` for a `pos_expired` reset). The owner (`MatrixSession`)
    /// discards exactly those from durable storage; it does NOT send a new
    /// `sync_start` and the fresh `sync` frames keep arriving on this socket.
    var onSyncReset: (([String]) -> Void)?
    /// Gateway asked for a fresh token (upstream 401). Caller supplies one via `reauth(token:)`.
    var onReauthNeeded: (() -> Void)?
    /// The socket closed / errored (receive loop ended). The owner
    /// (`MatrixSession`) drives reconnect/backoff. Not fired on a clean
    /// `disconnect()`.
    var onClosed: (() -> Void)?
    /// Current UI foreground state (protocol D.4): `true` iff the app is
    /// frontmost AND the device unlocked. Supplied by the owner
    /// (`MatrixSession`) so the gateway can answer each `ui_ping` (D.1) with the
    /// live value without owning the platform signals. Defaults to `false`
    /// (background) until wired — the safe direction (an extra wake, never a
    /// missed one, D.4).
    var foregroundStateProvider: (() -> Bool)?

    init(url: URL, accessToken: String, identity: Identity) {
        self.url = url
        self.accessToken = accessToken
        self.identity = identity
    }

    // MARK: - Lifecycle

    /// Open the socket, send `auth`, and resolve when `auth_ok` arrives.
    func connect() async throws(AppError) -> AuthResult {
        let session = URLSession(configuration: .default)
        // FLW5: phone client_id on the /ws upgrade (omitted when telemetry off), so
        // every gateway row carries it. Build a request to attach the header.
        var upgradeRequest = URLRequest(url: url)
        if let clientId = ClientIdentity.headerClientId() {
            upgradeRequest.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }
        let socket = session.webSocketTask(with: upgradeRequest)
        self.session = session
        self.socket = socket
        socket.resume()

        startReceiveLoop()
        startKeepalive()
        send(authFrame())

        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.authContinuation = continuation
            }
        } catch is CancellationError {
            throw AppError.cancelled
        } catch let error as GatewayError {
            throw error.asAppError
        } catch let error as URLError {
            throw AppError.network(error.localizedDescription)
        } catch {
            ErrorReporter.capture(error, context: "GatewayClient.connect")
            throw AppError.unexpected(error)
        }
    }

    func disconnect() {
        isClosing = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        failAllPending(GatewayError.socketClosed)
    }

    /// WebSocket-level keepalive. Without it an idle sliding-sync socket (the
    /// gateway long-polls upstream, so it can be silent for a while) gets reaped
    /// by NAT/iOS after ~15-30s — which dropped us right before the plugin's
    /// invite arrived. A ping every 20s keeps it alive; a failed ping surfaces
    /// the dead socket so reconnect kicks in.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let socket = self.socket else { return }
                AppLog.debug("🛰️↔ ping")
                socket.sendPing { error in
                    if let error { AppLog.log("⚙️ gateway ping failed: \(error)") }
                }
            }
        }
    }

    /// Re-auth in place (after `reauth`) without dropping the socket.
    func reauth(token: String) {
        accessToken = token
        send(authFrame())
    }

    // MARK: - Sync

    /// Start/resume the sliding-sync loop. `pos` (the room cursor) and
    /// `toDevicePos` (the to-device cursor) are the device's last
    /// durably-persisted positions (protocol D.1) — pass them on reconnect so the
    /// gateway resumes BOTH upstream cursors from there; omit either only on a
    /// genuinely fresh sync with no acked cursor of that kind yet.
    func startSync(body: [String: Any], pos: String? = nil, toDevicePos: String? = nil) {
        syncBody = body
        if let pos { syncPos = pos }
        if let toDevicePos { syncToDevicePos = toDevicePos }
        send(Self.syncStartFrame(body: body, pos: syncPos, toDevicePos: syncToDevicePos))
    }

    /// Build the `sync_start` frame (protocol D.1). Pure + `nonisolated` so the
    /// two-cursor wire contract is unit-testable. Each cursor is included only
    /// when present; omitting either is "fresh sync for that cursor" — the gateway
    /// then leaves that cursor at the start. The to-device cursor is resumed
    /// independently of `pos` (the two are separate counters).
    nonisolated static func syncStartFrame(body: [String: Any], pos: String?, toDevicePos: String?) -> [String: Any] {
        var frame: [String: Any] = ["t": "sync_start", "body": body]
        if let pos { frame["pos"] = pos }
        if let toDevicePos { frame["to_device_pos"] = toDevicePos }
        return frame
    }

    func updateSync(body: [String: Any]) {
        syncBody = body
        send(["t": "sync_update", "body": body])
    }

    /// Acknowledge that the device has DURABLY persisted everything in the acked
    /// frame: the timeline up to `pos` AND any to-device Megolm keys + crypto
    /// state, with the to-device cursor at `toDevicePos`. The gateway gates BOTH
    /// upstream cursors on this — it advances the room cursor to `pos` and the
    /// to-device cursor to `toDevicePos`, after which the homeserver may delete
    /// the acked to-device messages (protocol D.1, "Sync cursor & key delivery").
    /// `toDevicePos` is the latest to-device cursor on durable storage (the caller
    /// carries it forward on frames with no to-device section); absent leaves the
    /// to-device cursor unchanged.
    func syncAck(pos: String, toDevicePos: String? = nil) {
        syncPos = pos
        if let toDevicePos { syncToDevicePos = toDevicePos }
        send(Self.syncAckFrame(pos: pos, toDevicePos: toDevicePos))
    }

    /// Build the `sync_ack` frame (protocol D.1). Pure + `nonisolated` so the
    /// two-cursor wire contract is unit-testable. `to_device_pos` is ECHO-EXACT:
    /// the caller passes the acked frame's own `to_device_pos` (present iff that
    /// frame carried a to-device section), NEVER a carried-forward earlier value
    /// — the gateway validates the echo and closes with `bad_sync_ack` on a
    /// mismatch. Absent leaves the gateway's to-device cursor unchanged.
    nonisolated static func syncAckFrame(pos: String, toDevicePos: String?) -> [String: Any] {
        var frame: [String: Any] = ["t": "sync_ack", "pos": pos]
        if let toDevicePos { frame["to_device_pos"] = toDevicePos }
        return frame
    }

    func stopSync() { send(["t": "sync_stop"]) }

    // MARK: - UI foreground state (protocol D.1 / D.4)

    /// Report this device's current UI state to the gateway (protocol D.1
    /// `ui_state`). Sent as the reply to every `ui_ping` AND unsolicited the
    /// instant the foreground/background state flips, so a foreground→background
    /// change is observed without waiting for the next ping (D.4). `foreground`
    /// is `true` only when the app is frontmost AND the device unlocked. Drives
    /// the gateway's per-device push suppression (D.4); the client keeps its own
    /// in-app self-suppression independently.
    func sendUIState(foreground: Bool) {
        send(Self.uiStateFrame(foreground: foreground))
    }

    /// Build the `ui_state` frame (protocol D.1). Pure + `nonisolated` so the
    /// wire contract is unit-testable.
    nonisolated static func uiStateFrame(foreground: Bool) -> [String: Any] {
        ["t": "ui_state", "foreground": foreground]
    }

    // MARK: - Matrix C-S over the socket

    /// Forward a Matrix C-S call as a `req` frame; resolves on the matching `resp`.
    @discardableResult
    func request(method: String, path: String, body: [String: Any]? = nil) async throws(AppError) -> (status: Int, body: Data) {
        guard socket != nil else { throw AppError.notReady }
        reqCounter += 1
        let id = "r\(reqCounter)"
        var frame: [String: Any] = ["t": "req", "id": id, "method": method, "path": path]
        if let body { frame["body"] = body }
        AppLog.debug("🛰️→ req id=%@ %@ %@ body_keys=%@", id, method, path,
                     (body?.keys.sorted().joined(separator: ",")) ?? "-")
        do {
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                send(frame)
            }
        } catch is CancellationError {
            throw AppError.cancelled
        } catch let error as GatewayError {
            throw error.asAppError
        } catch let error as URLError {
            // The socket died mid-request (receive loop failed all pending). An
            // expected transport failure — reconnect is the owner's concern.
            throw AppError.network(error.localizedDescription)
        } catch {
            ErrorReporter.capture(error, context: "GatewayClient.request")
            throw AppError.unexpected(error)
        }
    }

    // MARK: - Internals

    private func authFrame() -> [String: Any] {
        [
            "t": "auth",
            "access_token": accessToken,
            "app_id": identity.appId,
            "client_version": identity.clientVersion,
            "platform": identity.platform,
            "release_channel": identity.releaseChannel
        ]
    }

    private func send(_ frame: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            AppLog.debug("🛰️→ send DROPPED (no socket or encode fail) t=%@", frame["t"] as? String ?? "?")
            return
        }
        // `auth` carries the access token — log only that it was sent, not the body.
        let t = frame["t"] as? String ?? "?"
        if t == "auth" {
            AppLog.debug("🛰️→ auth (token redacted) app_id=%@", identity.appId)
        } else if t != "req" { // req already logged with detail in request()
            AppLog.debug("🛰️→ %@ (%d bytes)", t, text.count)
        }
        socket.send(.string(text)) { error in
            if let error { AppLog.log("⚙️ gateway send error: \(error)") }
        }
    }

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled, let self, let socket = self.socket {
                do {
                    let message = try await socket.receive()
                    self.handle(message)
                } catch {
                    self.handleSocketError(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String else { return }

        AppLog.debug("🛰️← recv t=%@ (%d bytes)", type, text.count)
        switch type {
        case "auth_ok":
            let result = AuthResult(userId: obj["user_id"] as? String ?? "", deviceId: obj["device_id"] as? String ?? "")
            AppLog.debug("🛰️← auth_ok user=%@ device=%@", result.userId, result.deviceId)
            authContinuation?.resume(returning: result)
            authContinuation = nil
        case "auth_error":
            let reason = obj["reason"] as? String ?? "unknown"
            AppLog.debug("🛰️← auth_error reason=%@", reason)
            if let window = Self.unsupportedVersionWindow(from: obj) {
                authContinuation?.resume(throwing: GatewayError.unsupportedClientVersion(window))
            } else {
                authContinuation?.resume(throwing: GatewayError.authError(reason))
            }
            authContinuation = nil
        case "reauth":
            AppLog.debug("🛰️← reauth requested")
            onReauthNeeded?()
        case "resp":
            guard let id = obj["id"] as? String, let cont = pending.removeValue(forKey: id) else {
                AppLog.debug("🛰️← resp for unknown id=%@", obj["id"] as? String ?? "nil")
                return
            }
            let status = obj["status"] as? Int ?? 0
            let bodyData = (try? JSONSerialization.data(withJSONObject: obj["body"] ?? [:])) ?? Data()
            if !(200..<300).contains(status) {
                AppLog.debug("🛰️← resp id=%@ status=%d body=%@", id, status,
                             String(data: bodyData, encoding: .utf8)?.prefix(300).description ?? "")
            } else {
                AppLog.debug("🛰️← resp id=%@ status=%d (%d bytes)", id, status, bodyData.count)
            }
            cont.resume(returning: (status: status, body: bodyData))
        case "error":
            AppLog.log("⚙️ gateway error frame: \(obj["reason"] as? String ?? "")")
        case "sync":
            if let pos = obj["pos"] as? String { syncPos = pos }
            // D.1: top-level `to_device_pos`, present only when this batch advanced
            // the to-device cursor. MatrixSession persists it with the keys and
            // echoes it in `sync_ack`; here we only track the latest seen.
            if let tdp = obj["to_device_pos"] as? String { syncToDevicePos = tdp }
            let rooms = (obj["rooms"] as? [String: Any])?.count ?? 0
            AppLog.debug("🛰️← sync pos=%@ to_device_pos=%@ rooms=%d", obj["pos"] as? String ?? "nil",
                         obj["to_device_pos"] as? String ?? "nil", rooms)
            onSync?(obj)
        case "sync_reset":
            // D.1/D.2 cursor-expiry recovery. The homeserver rejected the room
            // cursor (`M_UNKNOWN_POS`); the gateway has ALREADY dropped the named
            // cursor(s) and re-initialised upstream from scratch on this same
            // socket. We MUST immediately discard exactly the named durable
            // cursor(s) so a later reconnect cannot replay a stale `pos`, then keep
            // consuming the fresh `sync` frames already streaming — WITHOUT sending
            // a new `sync_start`. Cursors not named stay valid (a `pos_expired`
            // reset names `["pos"]` only, leaving the to-device cursor intact).
            let cursors = Self.syncResetCursors(from: obj)
            let reason = obj["reason"] as? String ?? "unknown"
            AppLog.log("⚙️ gateway sync_reset reason=%@ cursors=%@", reason, cursors.joined(separator: ","))
            // Drop the in-memory copy of each named cursor so an in-place resume
            // never resends it. Durable storage is cleared by the owner via
            // `onSyncReset`. `to_device_pos` is preserved unless explicitly named.
            for cursor in cursors {
                switch cursor {
                case "pos": syncPos = nil
                case "to_device_pos": syncToDevicePos = nil
                default: break
                }
            }
            onSyncReset?(cursors)
        case "ui_ping":
            // D.1: foreground-state probe. MUST reply with a `ui_state` frame
            // carrying the live foreground value (D.4). No provider wired yet →
            // report background (`false`), the safe default that errs toward an
            // extra silent wake rather than a missed one.
            let foreground = foregroundStateProvider?() ?? false
            AppLog.debug("🛰️← ui_ping → ui_state foreground=%@", foreground ? "true" : "false")
            sendUIState(foreground: foreground)
        default:
            AppLog.debug("🛰️← UNHANDLED frame t=%@", type)
        }
    }

    /// Extract the `cursors` array from a `sync_reset` frame (protocol D.1). Pure +
    /// `nonisolated` so the wire contract is unit-testable. Returns the cursor names
    /// the device MUST discard from durable storage; a missing or non-string-array
    /// `cursors` field degrades to an empty list (discard nothing) rather than
    /// throwing — a malformed reset must never crash the client. Only string entries
    /// are kept.
    nonisolated static func syncResetCursors(from frame: [String: Any]) -> [String] {
        guard let cursors = frame["cursors"] as? [Any] else { return [] }
        return cursors.compactMap { $0 as? String }
    }

    nonisolated static func unsupportedVersionWindow(from frame: [String: Any]) -> VersionWindow? {
        guard frame["reason"] as? String == "unsupported_client_version" else { return nil }
        return VersionWindow(
            minClientVersion: frame["min_client_version"] as? String,
            maxClientVersion: frame["max_client_version"] as? String
        )
    }

    private func handleSocketError(_ error: Error) {
        AppLog.log("⚙️ gateway socket closed: \(error)")
        keepaliveTask?.cancel()
        keepaliveTask = nil
        failAllPending(error)
        // Reconnect/backoff is the caller's concern (MatrixSession owns retry).
        // Suppressed on a clean `disconnect()`.
        guard !isClosing else { return }
        onClosed?()
    }

    private func failAllPending(_ error: Error) {
        let conts = pending.values
        pending.removeAll()
        for cont in conts { cont.resume(throwing: error) }
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }
}
