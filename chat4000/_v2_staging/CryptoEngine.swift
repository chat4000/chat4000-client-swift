import Foundation
import MatrixSDKCrypto

// ─────────────────────────────────────────────────────────────────────────────
// STAGED — pre-integration (v2 gateway/Option-2 swap, B1).
//
// Outside `chat4000/Sources/` on purpose (see SyncModel.swift header): the app
// still links the full MatrixRustSDK, which can't coexist with this crypto-only
// lib. Compiled standalone against the vendored `MatrixSDKCrypto` package in a
// scratch SPM target. On the atomic swap (B3) this moves to
// `Sources/Matrix/CryptoEngine.swift` and `GatewayClient` is declared to
// conform to `GatewayRequesting`.
//
// Purpose: own the standalone Olm/Megolm machine and translate its crypto
// protocol into homeserver C-S calls sent over the gateway. We do NOT implement
// crypto — `OlmMachine` (the audited matrix-sdk-crypto FFI) does; this drives it:
//   • feed sync to-device/key-state in, drain its outgoing requests out
//     (keysUpload/keysQuery/keysClaim/toDevice/signatureUpload/keysBackup/
//      roomMessage) as gateway `req`s, then ack each via `markRequestAsSent`;
//   • encrypt a room event (megolm) after ensuring sessions + sharing the room
//     key, and PUT it as `m.room.encrypted` (protocol D.2);
//   • decrypt an inbound `m.room.encrypted` event to cleartext.
// ─────────────────────────────────────────────────────────────────────────────

/// The narrow homeserver-call seam CryptoEngine needs. `GatewayClient` already
/// exposes exactly this method, so on B3 it conforms with a one-line extension.
/// Keeping CryptoEngine behind a protocol (not the concrete client) keeps it
/// unit-testable with a mock transport.
@MainActor
protocol GatewayRequesting: AnyObject {
    @discardableResult
    func request(method: String, path: String, body: [String: Any]?) async throws -> (status: Int, body: Data)
}

enum CryptoEngineError: LocalizedError {
    case csRequestFailed(status: Int, path: String, body: String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case let .csRequestFailed(status, path, body):
            return "Homeserver C-S call \(path) failed (\(status)): \(body.prefix(200))"
        case .encodeFailed:
            return "Failed to encode a crypto request body"
        }
    }
}

@MainActor
final class CryptoEngine {
    private let machine: OlmMachine
    private let gateway: GatewayRequesting

    /// v1-equivalent posture: decrypt regardless of device trust. Hardening to
    /// cross-signing-required is a later step (we auto-enable cross-signing on
    /// the account, but gating decryption on it now would drop legitimate
    /// messages before verification flows exist).
    private let decryptionSettings = DecryptionSettings(senderDeviceTrustRequirement: .untrusted)

    /// Bound so a misbehaving machine that keeps regenerating requests can't spin
    /// forever; one or two passes is the normal case.
    private let maxPumpPasses = 20

    init(userId: String, deviceId: String, storePath: String, passphrase: String?, gateway: GatewayRequesting) throws {
        self.machine = try OlmMachine(userId: userId, deviceId: deviceId, path: storePath, passphrase: passphrase)
        self.gateway = gateway
    }

    // MARK: - Sync intake

    /// Feed one sync's e2ee state into the machine, then drain its outgoing
    /// requests. Call this BEFORE processing the sync's room events so freshly
    /// received room keys are available for decryption.
    func processSync(_ sync: GatewaySync) async throws {
        let deviceChanges = DeviceLists(changed: sync.deviceLists.changed, left: sync.deviceLists.left)
        _ = try machine.receiveSyncChanges(
            events: sync.toDevice.eventsJSON,
            deviceChanges: deviceChanges,
            keyCounts: sync.oneTimeKeyCounts,
            unusedFallbackKeys: sync.unusedFallbackKeyTypes,
            nextBatchToken: sync.pos ?? "",
            decryptionSettings: decryptionSettings
        )
        try await runOutgoingRequests()
    }

    // MARK: - Outgoing-request pump

    /// Drain `machine.outgoingRequests()` to the homeserver until empty (acking
    /// each), bounded by `maxPumpPasses`. `markRequestAsSent` can enqueue new
    /// requests (e.g. a key query surfacing identity changes), hence the loop.
    func runOutgoingRequests() async throws {
        for pass in 0..<maxPumpPasses {
            let requests = try machine.outgoingRequests()
            if requests.isEmpty { return }
            for request in requests {
                try await send(request)
            }
            if pass == maxPumpPasses - 1 {
                AppLog.log("⚙️ CryptoEngine pump hit cap (%d) — outgoing requests may remain", maxPumpPasses)
            }
        }
    }

    private func send(_ request: Request) async throws {
        switch request {
        case let .keysUpload(requestId, body):
            let resp = try await post("/_matrix/client/v3/keys/upload", jsonBody: body)
            try machine.markRequestAsSent(requestId: requestId, requestType: .keysUpload, responseBody: resp)

        case let .keysQuery(requestId, users):
            // The FFI hands us the user list; the C-S body is `{device_keys:{u:[]}}`.
            var deviceKeys: [String: Any] = [:]
            for user in users { deviceKeys[user] = [String]() }
            let resp = try await post("/_matrix/client/v3/keys/query", dictBody: ["device_keys": deviceKeys])
            try machine.markRequestAsSent(requestId: requestId, requestType: .keysQuery, responseBody: resp)

        case let .keysClaim(requestId, oneTimeKeys):
            let resp = try await post("/_matrix/client/v3/keys/claim", dictBody: ["one_time_keys": oneTimeKeys])
            try machine.markRequestAsSent(requestId: requestId, requestType: .keysClaim, responseBody: resp)

        case let .toDevice(requestId, eventType, body):
            // requestId doubles as the idempotent txn id.
            let path = "/_matrix/client/v3/sendToDevice/\(encode(eventType))/\(encode(requestId))"
            let resp = try await put(path, jsonBody: body)
            try machine.markRequestAsSent(requestId: requestId, requestType: .toDevice, responseBody: resp)

        case let .signatureUpload(requestId, body):
            let resp = try await post("/_matrix/client/v3/keys/signatures/upload", jsonBody: body)
            try machine.markRequestAsSent(requestId: requestId, requestType: .signatureUpload, responseBody: resp)

        case let .keysBackup(requestId, version, rooms):
            let path = "/_matrix/client/v3/room_keys/keys?version=\(encode(version))"
            let resp = try await put(path, jsonBody: rooms)
            try machine.markRequestAsSent(requestId: requestId, requestType: .keysBackup, responseBody: resp)

        case let .roomMessage(requestId, roomId, eventType, content):
            let path = "/_matrix/client/v3/rooms/\(encode(roomId))/send/\(encode(eventType))/\(encode(requestId))"
            let resp = try await put(path, jsonBody: content)
            try machine.markRequestAsSent(requestId: requestId, requestType: .roomMessage, responseBody: resp)
        }
    }

    // MARK: - Room key / encryption lifecycle

    /// Tell the machine a room is megolm-encrypted (from `m.room.encryption` in
    /// sync). Required before `encrypt`/`shareRoomKey` for that room.
    func markRoomEncrypted(_ roomId: String) throws {
        try machine.setRoomAlgorithm(roomId: roomId, algorithm: .megolmV1AesSha2)
    }

    /// Keep the machine's tracked-user set in step with room membership so it
    /// queries/claims keys for the right devices.
    func updateTrackedUsers(_ users: [String]) throws {
        try machine.updateTrackedUsers(users: users)
    }

    /// Encrypt `content` for `roomId` and send it as `m.room.encrypted`
    /// (protocol D.2). `cleartextEnvelope` carries the fields that ride OUTSIDE
    /// the ciphertext on the event (protocol E): `chat4000.push` and, for turn
    /// events, `m.relates_to`. Ensures olm sessions + shares the room key first.
    /// Returns the homeserver `event_id`.
    @discardableResult
    func encryptAndSend(
        roomId: String,
        recipients: [String],
        eventType: String = "m.room.message",
        content: [String: Any],
        cleartextEnvelope: [String: Any] = [:]
    ) async throws -> String? {
        if let claim = try machine.getMissingSessions(users: recipients) {
            try await send(claim)
            try await runOutgoingRequests()
        }

        let shareRequests = try machine.shareRoomKey(roomId: roomId, users: recipients, settings: encryptionSettings)
        for request in shareRequests { try await send(request) }

        let plaintext = try jsonString(content)
        let encrypted = try machine.encrypt(roomId: roomId, eventType: eventType, content: plaintext)

        // `encrypt` returns the `m.room.encrypted` content (algorithm,
        // ciphertext, sender_key, …). Splice the cleartext envelope fields onto
        // that object so the homeserver can read `chat4000.push` / aggregate
        // `m.relates_to` without seeing plaintext.
        var outer = (try? dict(fromJSON: encrypted)) ?? [:]
        for (key, value) in cleartextEnvelope { outer[key] = value }

        let txnId = UUID().uuidString
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/send/m.room.encrypted/\(encode(txnId))"
        let resp = try await put(path, dictBody: outer)
        return (try? dict(fromJSON: resp))?["event_id"] as? String
    }

    /// Decrypt an inbound `m.room.encrypted` event (the full event JSON) to its
    /// cleartext event JSON. Throws if the session is missing/undecryptable —
    /// callers should tolerate that (the key may arrive on a later sync).
    func decrypt(eventJSON: String, roomId: String) throws -> String {
        let result = try machine.decryptRoomEvent(
            event: eventJSON,
            roomId: roomId,
            handleVerificationEvents: false,
            strictShields: false,
            decryptionSettings: decryptionSettings
        )
        return result.clearEvent
    }

    // MARK: - Settings

    private var encryptionSettings: EncryptionSettings {
        EncryptionSettings(
            algorithm: .megolmV1AesSha2,
            rotationPeriod: 604_800,        // 1 week (matrix default)
            rotationPeriodMsgs: 100,        // matrix default
            historyVisibility: .shared,
            onlyAllowTrustedDevices: false, // mirrors decryptionSettings posture
            errorOnVerifiedUserProblem: false
        )
    }

    // MARK: - C-S transport helpers

    /// POST/PUT a request whose body the FFI already handed us as a JSON object
    /// string. Returns the response body as a string for `markRequestAsSent`.
    private func post(_ path: String, jsonBody: String) async throws -> String {
        try await call("POST", path, body: try? dict(fromJSON: jsonBody))
    }

    private func put(_ path: String, jsonBody: String) async throws -> String {
        try await call("PUT", path, body: try? dict(fromJSON: jsonBody))
    }

    private func post(_ path: String, dictBody: [String: Any]) async throws -> String {
        try await call("POST", path, body: dictBody)
    }

    private func put(_ path: String, dictBody: [String: Any]) async throws -> String {
        try await call("PUT", path, body: dictBody)
    }

    private func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> String {
        let (status, data) = try await gateway.request(method: method, path: path, body: body)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        guard (200..<300).contains(status) else {
            throw CryptoEngineError.csRequestFailed(status: status, path: path, body: text)
        }
        return text
    }

    // MARK: - JSON helpers

    private func dict(fromJSON json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CryptoEngineError.encodeFailed }
        return obj
    }

    private func jsonString(_ obj: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8)
        else { throw CryptoEngineError.encodeFailed }
        return string
    }

    /// Percent-encode a single path segment (room ids contain `!`, `:`, `@`).
    private func encode(_ segment: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
