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

    enum GatewayError: LocalizedError {
        case badURL
        case notConnected
        case authError(String)
        case socketClosed
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL: "Invalid gateway URL"
            case .notConnected: "Gateway not connected"
            case .authError(let r): "Gateway auth failed: \(r)"
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

    /// Pushes each `sync` frame's top-level object (pos/rooms/extensions).
    var onSync: (([String: Any]) -> Void)?
    /// Gateway asked for a fresh token (upstream 401). Caller supplies one via `reauth(token:)`.
    var onReauthNeeded: (() -> Void)?
    /// The socket closed / errored (receive loop ended). The owner
    /// (`MatrixSession`) drives reconnect/backoff. Not fired on a clean
    /// `disconnect()`.
    var onClosed: (() -> Void)?

    init(url: URL, accessToken: String, identity: Identity) {
        self.url = url
        self.accessToken = accessToken
        self.identity = identity
    }

    // MARK: - Lifecycle

    /// Open the socket, send `auth`, and resolve when `auth_ok` arrives.
    func connect() async throws(AppError) -> AuthResult {
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
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

    /// Start/resume the sliding-sync loop. `pos` is the device's last
    /// durably-persisted position (protocol D.1) — pass it on reconnect so the
    /// gateway resumes upstream from there; omit for a fresh sync.
    func startSync(body: [String: Any], pos: String? = nil) {
        syncBody = body
        if let pos { syncPos = pos }
        var frame: [String: Any] = ["t": "sync_start", "body": body]
        if let syncPos { frame["pos"] = syncPos }
        send(frame)
    }

    func updateSync(body: [String: Any]) {
        syncBody = body
        send(["t": "sync_update", "body": body])
    }

    /// Acknowledge that the device has DURABLY persisted everything in the sync
    /// up to `pos` (incl. to-device Megolm keys + crypto state). The gateway
    /// gates the upstream cursor on this — it will not advance (and the
    /// homeserver will not delete the acked to-device messages) until it
    /// arrives (protocol D.1, "Sync cursor & key delivery").
    func syncAck(pos: String) {
        syncPos = pos
        send(["t": "sync_ack", "pos": pos])
    }

    func stopSync() { send(["t": "sync_stop"]) }

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
            authContinuation?.resume(throwing: GatewayError.authError(reason))
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
            let rooms = (obj["rooms"] as? [String: Any])?.count ?? 0
            AppLog.debug("🛰️← sync pos=%@ rooms=%d", obj["pos"] as? String ?? "nil", rooms)
            onSync?(obj)
        default:
            AppLog.debug("🛰️← UNHANDLED frame t=%@", type)
        }
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
