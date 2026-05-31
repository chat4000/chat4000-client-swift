import Foundation

/// Native client for the chat4000 WS gateway (protocol D): a single WebSocket
/// that authenticates, runs the sliding-sync loop, and multiplexes Matrix C-S
/// calls as `req`/`resp` frames. This is the **transport half** of the
/// gateway-native client (Option 2). End-to-end crypto (Olm/Megolm) and the
/// room/timeline model are layered on top of this.
///
/// Frame shapes mirror `chat4000-matrix-ws-proxy/src/protocol.rs`.
@MainActor
final class GatewayClient {
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
    }

    private let url: URL
    private let identity: Identity
    private var accessToken: String

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?

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

    init(url: URL, accessToken: String, identity: Identity) {
        self.url = url
        self.accessToken = accessToken
        self.identity = identity
    }

    // MARK: - Lifecycle

    /// Open the socket, send `auth`, and resolve when `auth_ok` arrives.
    func connect() async throws -> AuthResult {
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        socket.resume()

        startReceiveLoop()
        send(authFrame())

        return try await withCheckedThrowingContinuation { continuation in
            self.authContinuation = continuation
        }
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        failAllPending(GatewayError.socketClosed)
    }

    /// Re-auth in place (after `reauth`) without dropping the socket.
    func reauth(token: String) {
        accessToken = token
        send(authFrame())
    }

    // MARK: - Sync

    func startSync(body: [String: Any]) {
        syncBody = body
        var frame: [String: Any] = ["t": "sync_start", "body": body]
        if let syncPos { frame["pos"] = syncPos }
        send(frame)
    }

    func updateSync(body: [String: Any]) {
        syncBody = body
        send(["t": "sync_update", "body": body])
    }

    func stopSync() { send(["t": "sync_stop"]) }

    // MARK: - Matrix C-S over the socket

    /// Forward a Matrix C-S call as a `req` frame; resolves on the matching `resp`.
    @discardableResult
    func request(method: String, path: String, body: [String: Any]? = nil) async throws -> (status: Int, body: Data) {
        guard socket != nil else { throw GatewayError.notConnected }
        reqCounter += 1
        let id = "r\(reqCounter)"
        var frame: [String: Any] = ["t": "req", "id": id, "method": method, "path": path]
        if let body { frame["body"] = body }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(frame)
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
            "release_channel": identity.releaseChannel,
        ]
    }

    private func send(_ frame: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
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

        switch type {
        case "auth_ok":
            let result = AuthResult(userId: obj["user_id"] as? String ?? "", deviceId: obj["device_id"] as? String ?? "")
            authContinuation?.resume(returning: result)
            authContinuation = nil
        case "auth_error":
            let reason = obj["reason"] as? String ?? "unknown"
            authContinuation?.resume(throwing: GatewayError.authError(reason))
            authContinuation = nil
        case "reauth":
            onReauthNeeded?()
        case "resp":
            guard let id = obj["id"] as? String, let cont = pending.removeValue(forKey: id) else { return }
            let status = obj["status"] as? Int ?? 0
            let bodyData = (try? JSONSerialization.data(withJSONObject: obj["body"] ?? [:])) ?? Data()
            cont.resume(returning: (status: status, body: bodyData))
        case "error":
            AppLog.log("⚙️ gateway error frame: \(obj["reason"] as? String ?? "")")
        case "sync":
            if let pos = obj["pos"] as? String { syncPos = pos }
            onSync?(obj)
        default:
            break
        }
    }

    private func handleSocketError(_ error: Error) {
        AppLog.log("⚙️ gateway socket closed: \(error)")
        failAllPending(error)
        // Reconnect/backoff is the caller's concern (MatrixSession owns retry).
    }

    private func failAllPending(_ error: Error) {
        let conts = pending.values
        pending.removeAll()
        for cont in conts { cont.resume(throwing: error) }
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }
}
